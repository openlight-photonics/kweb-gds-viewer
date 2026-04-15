import * as vscode from "vscode";
import { ChildProcess, spawn } from "child_process";
import * as path from "path";
import * as http from "http";
import * as os from "os";
import * as fs from "fs";

const DEFAULT_PORT = 8078;
const STARTUP_TIMEOUT_MS = 15000;
const HEALTH_POLL_MS = 500;

/** kweb>=1 / 2.x (canvas2canvas viewer; needs Python >=3.10 for 1.x, >=3.11 for 2.x) */
const KWEB_PROBE_MODERN = "import kweb.default, uvicorn";
/** Legacy PyPI kweb 0.1.x (gdsfactory) — only exposes kweb.main:app, works on older Python */
const KWEB_PROBE_LEGACY = "import kweb.main, uvicorn";

type PythonInvocation = {
  /** Original candidate string for logs */
  display: string;
  executable: string;
  argvPrefix: string[];
};

function parsePythonCandidate(candidate: string): PythonInvocation {
  const trimmed = candidate.trim();
  if (process.platform === "win32" && /^py(\.exe)?(\s+|$)/i.test(trimmed)) {
    const parts = trimmed.split(/\s+/).filter(Boolean);
    return {
      display: trimmed,
      executable: parts[0],
      argvPrefix: parts.slice(1),
    };
  }
  return { display: trimmed, executable: trimmed, argvPrefix: [] };
}

type KwebFlavor = "modern" | "legacy";
/** kweb 2.x: /view?file=… + /status; kweb 1.x: /gds/{path}, no /status */
type KwebViewerUrlStyle = "query" | "path";

export class KwebServer {
  private process: ChildProcess | null = null;
  private _port: number = DEFAULT_PORT;
  private _ready = false;
  private _filesLocation = "";
  private _kwebFlavor: KwebFlavor = "modern";
  private _viewerUrlStyle: KwebViewerUrlStyle = "query";
  private startupFailureMessage = "";
  private outputChannel: vscode.OutputChannel;

  constructor() {
    this.outputChannel = vscode.window.createOutputChannel("kweb GDS Server");
  }

  get port(): number {
    return this._port;
  }

  get ready(): boolean {
    return this._ready;
  }

  get baseUrl(): string {
    return `http://127.0.0.1:${this._port}`;
  }

  /** kweb GDS Server output channel — for viewer / forwarding diagnostics. */
  appendDiagnosticLine(message: string): void {
    this.outputChannel.appendLine(message);
  }

  viewUrl(gdsAbsPath: string, revision?: string): string {
    if (this._kwebFlavor === "legacy") {
      const suffix = revision ? `&v=${encodeURIComponent(revision)}` : "";
      return `${this.baseUrl}/gds?gds_file=${encodeURIComponent(gdsAbsPath)}${suffix}`;
    }

    const relative = path.relative(this._filesLocation, gdsAbsPath).replace(/\\/g, "/");
    const vq = revision ? `&v=${encodeURIComponent(revision)}` : "";
    const vpath = revision ? `?v=${encodeURIComponent(revision)}` : "";

    if (this._viewerUrlStyle === "query") {
      return `${this.baseUrl}/view?file=${encodeURIComponent(relative)}${vq}`;
    }

    const lower = gdsAbsPath.toLowerCase();
    if (lower.endsWith(".oas")) {
      const enc = relative.split("/").filter(Boolean).map(encodeURIComponent).join("/");
      return `${this.baseUrl}/file/${enc}${vpath}`;
    }

    // kweb path route resolves (fileslocation / gds_name).with_suffix(".gds").
    // Stripping ".gds" from "cell.generated.gds" yields "cell.generated", and
    // Path("cell.generated").with_suffix(".gds") becomes "cell.gds" — wrong file.
    const enc = relative.split("/").filter(Boolean).map(encodeURIComponent).join("/");
    return `${this.baseUrl}/gds/${enc}${vpath}`;
  }

  async start(filesLocation: string, port?: number): Promise<void> {
    if (this._ready && this._filesLocation === filesLocation) {
      return;
    }

    if (this.process) {
      await this.stop();
    }

    this._filesLocation = filesLocation;
    this._port = port ?? DEFAULT_PORT;
    this.startupFailureMessage = "";

    const { inv: pyInv, flavor } = await this.findPython();
    this._kwebFlavor = flavor;
    const asgiTarget = flavor === "legacy" ? "kweb.main:app" : "kweb.default:app";
    this.outputChannel.appendLine(`Starting kweb server...`);
    this.outputChannel.appendLine(`  Python: ${pyInv.display}`);
    this.outputChannel.appendLine(`  kweb mode: ${flavor} (${asgiTarget})`);
    this.outputChannel.appendLine(`  Files location: ${filesLocation}`);
    this.outputChannel.appendLine(`  Port: ${this._port}`);

    this.process = spawn(
      pyInv.executable,
      [
        ...pyInv.argvPrefix,
        "-m",
        "uvicorn",
        asgiTarget,
        "--host", "127.0.0.1",
        "--port", String(this._port),
      ],
      {
        env: {
          ...process.env,
          KWEB_FILESLOCATION: filesLocation,
        },
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      }
    );

    this.process.stdout?.on("data", (data: Buffer) => {
      this.outputChannel.appendLine(data.toString().trim());
    });

    this.process.stderr?.on("data", (data: Buffer) => {
      const message = data.toString().trim();
      if (message) {
        this.outputChannel.appendLine(message);
        if (stderrLooksLikeFailure(message)) {
          this.startupFailureMessage = message;
        }
      }
    });

    this.process.on("exit", (code) => {
      this.outputChannel.appendLine(`kweb server exited with code ${code}`);
      if (!this._ready && !this.startupFailureMessage) {
        this.startupFailureMessage = `kweb server exited before becoming ready (code ${code ?? "unknown"}).`;
      }
      this._ready = false;
      this.process = null;
    });

    this.process.on("error", (err) => {
      this.outputChannel.appendLine(`kweb server error: ${err.message}`);
      this.startupFailureMessage = err.message;
      this._ready = false;
    });

    try {
      await this.waitForReady();
    } catch (error) {
      await this.stop();
      throw error;
    }
  }

  async stop(): Promise<void> {
    if (!this.process) return;
    this.outputChannel.appendLine("Stopping kweb server...");
    this._ready = false;

    return new Promise((resolve) => {
      if (!this.process) {
        resolve();
        return;
      }

      const timeout = setTimeout(() => {
        this.process?.kill("SIGKILL");
        resolve();
      }, 3000);

      this.process.on("exit", () => {
        clearTimeout(timeout);
        resolve();
      });

      this.process.kill("SIGTERM");
      this.process = null;
    });
  }

  async restart(filesLocation?: string): Promise<void> {
    await this.stop();
    await this.start(filesLocation ?? this._filesLocation, this._port);
  }

  dispose(): void {
    this.stop();
    this.outputChannel.dispose();
  }

  private async waitForReady(): Promise<void> {
    const start = Date.now();

    while (Date.now() - start < STARTUP_TIMEOUT_MS) {
      if (!this.process) {
        throw new Error(
          this.augmentKwebImportError(
            this.startupFailureMessage || "kweb server exited before becoming ready."
          )
        );
      }

      try {
        const ok = await this.healthCheck();
        if (ok) {
          this._ready = true;
          const statusOk = await this.httpGetReturns200(`${this.baseUrl}/status`);
          this._viewerUrlStyle = statusOk ? "query" : "path";
          this.outputChannel.appendLine(
            `kweb server is ready (viewer API: ${this._viewerUrlStyle === "query" ? "kweb 2.x /view" : "kweb 1.x /gds"}).`
          );
          return;
        }
      } catch {
        // not ready yet
      }
      await sleep(HEALTH_POLL_MS);
    }

    this.outputChannel.appendLine("kweb server startup timed out.");
    throw new Error(
      this.augmentKwebImportError(
        this.startupFailureMessage ||
          "kweb server did not become ready within timeout. Verify that kweb, uvicorn, and port 8078 are available."
      )
    );
  }

  private augmentKwebImportError(message: string): string {
    if (/could not import module/i.test(message) && /kweb/i.test(message)) {
      return (
        `${message} — Install PyPI kweb + uvicorn, or use Python 3.10+ for kweb>=1 ` +
        `(kweb.default). On Python 3.8, legacy kweb 0.1.x (kweb.main) is supported.`
      );
    }
    return message;
  }

  /** kweb 0.1 / some stacks expose /status; kweb 1.x+ default app often has no /status but serves GET / */
  private healthCheck(): Promise<boolean> {
    return this.httpGetReturns200(`${this.baseUrl}/status`).then((ok) =>
      ok ? true : this.httpGetReturns200(`${this.baseUrl}/`)
    );
  }

  private httpGetReturns200(url: string): Promise<boolean> {
    return new Promise((resolve) => {
      const req = http.get(url, (res) => {
        const ok = res.statusCode === 200;
        res.resume();
        resolve(ok);
      });
      req.on("error", () => resolve(false));
      req.setTimeout(1500, () => {
        req.destroy();
        resolve(false);
      });
    });
  }

  private async findPython(): Promise<{ inv: PythonInvocation; flavor: KwebFlavor }> {
    const candidates: string[] = [];
    const seen = new Set<string>();

    const push = (c: string | undefined) => {
      const t = c?.trim();
      if (t && !seen.has(t)) {
        seen.add(t);
        candidates.push(t);
      }
    };

    const cfg = vscode.workspace.getConfiguration("kweb-gds-viewer");
    push(cfg.get<string>("kwebPythonPath"));

    const homeDir = process.env.HOME || process.env.USERPROFILE;
    if (homeDir) {
      // Installer venv created by /opt/tools/kweb-gds-viewer/install
      const installerVenvPython = path.join(homeDir, ".local", "share", "kweb-gds-viewer", "venv", "bin", "python");
      try {
        if (fs.existsSync(installerVenvPython)) {
          push(installerVenvPython);
        }
      } catch {
        // ignore
      }
    }

    // Typical user-local conda-forge installs (no setting required per workspace)
    if (homeDir) {
      for (const rel of [
        path.join("miniforge3", "bin", "python"),
        path.join("miniforge3", "bin", "python3"),
        path.join("mambaforge", "bin", "python"),
        path.join("mambaforge", "bin", "python3"),
      ]) {
        const abs = path.join(homeDir, rel);
        try {
          if (fs.existsSync(abs)) {
            push(abs);
          }
        } catch {
          // ignore
        }
      }
    }

    try {
      const ext = vscode.extensions.getExtension("ms-python.python");
      if (ext) {
        if (!ext.isActive) await ext.activate();
        const api = ext.exports;
        const envPath = api?.environments?.getActiveEnvironmentPath?.();
        push(envPath?.path);
      }
    } catch {
      // fall through
    }

    const pyCfg = vscode.workspace.getConfiguration("python");
    push(pyCfg.get<string>("defaultInterpreterPath"));

    if (process.platform === "win32") {
      push("python");
      push("python3");
      push("py -3");
    } else {
      push("python3");
      push("python");
    }

    for (const candidate of candidates) {
      const inv = parsePythonCandidate(candidate);
      if (!inv.executable) {
        continue;
      }
      if (await this.canRunPythonSnippet(inv, KWEB_PROBE_MODERN, { kwebFilesLocation: os.tmpdir() })) {
        return { inv, flavor: "modern" };
      }
      if (await this.canRunPythonSnippet(inv, KWEB_PROBE_LEGACY)) {
        return { inv, flavor: "legacy" };
      }
    }

    const hint = candidates.length
      ? `Checked: ${candidates.join(", ")}`
      : "No Python candidates were discovered from Cursor or the Python extension.";
    throw new Error(
      "Could not find a Python with kweb+uvicorn: either `import kweb.default, uvicorn` (kweb 2.x, Python 3.11+) " +
        "or `import kweb.main, uvicorn` (older kweb 0.1.x; PyPI wheels still need Python 3.9+). " +
        `${hint} ` +
        "Run /opt/tools/kweb-gds-viewer/install to set up the required Python environment, " +
        "or set optocompiler-plus.kwebPythonPath, or install Miniforge in your home directory and pip install -r scripts/ocp-kweb-pins.txt."
    );
  }

  private canRunPythonSnippet(
    inv: PythonInvocation,
    snippet: string,
    opts?: { kwebFilesLocation?: string }
  ): Promise<boolean> {
    return new Promise((resolve) => {
      try {
        const env = { ...process.env };
        if (opts?.kwebFilesLocation) {
          env.KWEB_FILESLOCATION = opts.kwebFilesLocation;
        }
        const proc = spawn(inv.executable, [...inv.argvPrefix, "-c", snippet], {
          env,
          stdio: "ignore",
          windowsHide: true,
          timeout: 8000,
        });
        proc.on("exit", (code) => resolve(code === 0));
        proc.on("error", () => resolve(false));
      } catch {
        resolve(false);
      }
    });
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function stderrLooksLikeFailure(message: string): boolean {
  const line = message.split("\n")[0]?.trim() ?? "";
  if (/^INFO:/i.test(line) || /^DEBUG:/i.test(line)) {
    return false;
  }
  return (
    /^ERROR:/i.test(line) ||
    /^WARNING:/i.test(line) ||
    /traceback|exception|error:|fatal:|importerror|modulenotfound|could not import/i.test(
      message
    )
  );
}
