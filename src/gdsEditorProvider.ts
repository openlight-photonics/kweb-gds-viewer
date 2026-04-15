import * as vscode from "vscode";
import * as path from "path";
import { KwebServer } from "./kwebServer";

const activeEditors: Set<GdsEditorProvider> = new Set();

export class GdsEditorProvider implements vscode.CustomReadonlyEditorProvider {
  private currentWebviewPanel: vscode.WebviewPanel | null = null;

  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly kwebServer: KwebServer
  ) {}

  static register(context: vscode.ExtensionContext, kwebServer: KwebServer): vscode.Disposable {
    const provider = new GdsEditorProvider(context, kwebServer);
    return vscode.window.registerCustomEditorProvider(
      "kweb-gds-viewer.gdsEditor",
      provider,
      {
        webviewOptions: { retainContextWhenHidden: true },
        supportsMultipleEditorsPerDocument: false,
      }
    );
  }

  static refreshActive(): void {
    for (const editor of activeEditors) {
      editor.currentWebviewPanel?.webview.postMessage({ command: "refresh" });
    }
  }

  async openCustomDocument(
    uri: vscode.Uri,
    _openContext: vscode.CustomDocumentOpenContext,
    _token: vscode.CancellationToken
  ): Promise<vscode.CustomDocument> {
    return { uri, dispose: () => {} };
  }

  async resolveCustomEditor(
    document: vscode.CustomDocument,
    webviewPanel: vscode.WebviewPanel,
    _token: vscode.CancellationToken
  ): Promise<void> {
    this.currentWebviewPanel = webviewPanel;
    activeEditors.add(this);

    webviewPanel.onDidDispose(() => {
      activeEditors.delete(this);
      if (this.currentWebviewPanel === webviewPanel) {
        this.currentWebviewPanel = null;
      }
    });

    const webview = webviewPanel.webview;
    webview.options = {
      enableScripts: true,
      localResourceRoots: [
        vscode.Uri.joinPath(this.context.extensionUri, "assets"),
        vscode.Uri.joinPath(this.context.extensionUri, "dist"),
      ],
    };

    if (document.uri.scheme !== "file" || !document.uri.fsPath) {
      webview.html = this.getUnavailableHtml(
        webview,
        document.uri.path || document.uri.toString(),
        "The GDS viewer currently supports local file workspace resources only."
      );
      return;
    }

    const filePath = document.uri.fsPath;
    const fileName = path.basename(filePath);
    const dirPath = path.dirname(filePath);
    try {
      await this.kwebServer.start(dirPath);
      const internalUrl = this.kwebServer.viewUrl(filePath, String(Date.now()));
      const viewerUrl = await this.resolveKwebViewerUrl(internalUrl);
      if (viewerUrl !== internalUrl) {
        this.kwebServer.appendDiagnosticLine(
          `GDS viewer: using forwarded URL for ${fileName} (Remote-SSH). If kweb shows "No gds found", the webview may not be reaching this host — check port forwarding and kweb GDS Viewer files location.`
        );
      }
      webview.html = this.getKwebHtml(webview, fileName, viewerUrl);

      webview.onDidReceiveMessage(async (msg) => {
        if (msg.command === "refresh") {
          try {
            await this.kwebServer.restart();
            const newInternal = this.kwebServer.viewUrl(filePath, String(Date.now()));
            const newViewer = await this.resolveKwebViewerUrl(newInternal);
            await webview.postMessage({ command: "updateUrl", url: newViewer });
          } catch {
            // ignore
          }
        } else if (msg.command === "exportGds") {
          await this.exportDocument(document.uri, fileName);
        }
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      webview.html = this.getUnavailableHtml(webview, fileName, message);
    }
  }

  private async exportDocument(uri: vscode.Uri, fileName: string): Promise<void> {
    const defaultName = fileName.toLowerCase().endsWith(".gds") ? fileName : `${fileName}.gds`;
    const targetUri = await vscode.window.showSaveDialog({
      defaultUri: vscode.Uri.file(path.join(path.dirname(uri.fsPath), defaultName)),
      filters: {
        "GDS Files": ["gds"],
      },
      saveLabel: "Export GDS",
    });
    if (!targetUri) {
      return;
    }

    const gdsBytes = await vscode.workspace.fs.readFile(uri);
    await vscode.workspace.fs.writeFile(targetUri, gdsBytes);
    void vscode.window.showInformationMessage(`Exported GDS to ${targetUri.fsPath}`);
  }

  /* ------------------------------------------------------------------ */
  /*  kweb iframe viewer                                                 */
  /* ------------------------------------------------------------------ */

  /**
   * Webviews run on the client; under Remote-SSH, plain http://127.0.0.1:8078
   * would hit the laptop, not the host running kweb. asExternalUri tunnels it.
   */
  private async resolveKwebViewerUrl(internalHttpUrl: string): Promise<string> {
    try {
      const mapped = await vscode.env.asExternalUri(vscode.Uri.parse(internalHttpUrl));
      return mapped.toString();
    } catch {
      return internalHttpUrl;
    }
  }

  private getKwebHtml(
    webview: vscode.Webview,
    fileName: string,
    kwebUrl: string
  ): string {
    const nonce = getNonce();

    return /* html */ `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <meta http-equiv="Content-Security-Policy"
    content="default-src 'none';
             style-src ${webview.cspSource} 'unsafe-inline';
             script-src 'nonce-${nonce}';
             frame-src http://127.0.0.1:* http://localhost:* http://[::1]:* https://127.0.0.1:* https://localhost:*;
             connect-src http://127.0.0.1:* ws://127.0.0.1:* wss://127.0.0.1:* http://localhost:* ws://localhost:* wss://localhost:* https://127.0.0.1:* https://localhost:*;"/>
  <title>${escapeHtml(fileName)}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { width: 100%; height: 100%; overflow: hidden;
      background: var(--vscode-editor-background, #1e1e1e);
      font-family: var(--vscode-font-family, system-ui);
      color: var(--vscode-foreground, #ccc); }
    #toolbar {
      display: flex; align-items: center; justify-content: space-between;
      padding: 4px 8px; height: 32px; flex-shrink: 0;
      background: var(--vscode-editorWidget-background, #252526);
      border-bottom: 1px solid var(--vscode-panel-border, #333);
    }
    #toolbar button {
      background: var(--vscode-button-secondaryBackground, #3a3d41);
      color: var(--vscode-button-secondaryForeground, #ccc);
      border: 1px solid var(--vscode-input-border, #444);
      border-radius: 3px; padding: 2px 10px; font-size: 12px;
      cursor: pointer; height: 24px;
    }
    #toolbar button:hover { background: var(--vscode-button-secondaryHoverBackground, #45484d); }
    #toolbar .title { font-size: 12px; opacity: 0.7; }
    #toolbar .badge {
      font-size: 10px; padding: 1px 6px; border-radius: 8px;
      background: #2ecc7133; color: #2ecc71; margin-left: 6px;
    }
    #viewer-frame {
      width: 100%; height: calc(100vh - 32px); border: none;
    }
    #loading {
      display: flex; align-items: center; justify-content: center;
      height: calc(100vh - 32px); gap: 10px;
    }
    #refresh-overlay {
      display: none; position: absolute;
      top: 32px; left: 0; right: 0; bottom: 0;
      align-items: center; justify-content: center; gap: 10px;
      background: rgba(0, 0, 0, 0.35);
      z-index: 10;
    }
    .spinner {
      width: 24px; height: 24px;
      border: 2px solid var(--vscode-foreground, #ccc);
      border-top-color: transparent; border-radius: 50%;
      animation: spin 0.8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
  </style>
</head>
<body style="position:relative;">
  <div id="toolbar">
    <div>
      <span class="title">${escapeHtml(fileName)}</span>
      <span class="badge">kweb</span>
    </div>
    <div style="display:flex;gap:6px;">
      <button id="btn-export" title="Save a copy of this GDS">Export GDS</button>
      <button id="btn-refresh" title="Reload viewer">Refresh</button>
    </div>
  </div>
  <div id="loading">
    <div class="spinner"></div>
    <span>Starting kweb server...</span>
  </div>
  <iframe id="viewer-frame" style="display:none;"></iframe>
  <div id="refresh-overlay">
    <div class="spinner"></div>
    <span>Loading...</span>
  </div>

  <script nonce="${nonce}">
  (function() {
    const vscode = acquireVsCodeApi();
    const iframe = document.getElementById('viewer-frame');
    const loading = document.getElementById('loading');
    const refreshOverlay = document.getElementById('refresh-overlay');
    const kwebUrl = ${JSON.stringify(kwebUrl)};
    var viewerLoaded = false;

    function loadViewer(url) {
      var timeoutId = setTimeout(function() {
        loading.style.display = 'none';
        refreshOverlay.style.display = 'none';
        iframe.style.display = 'block';
        viewerLoaded = true;
      }, 8000);
      iframe.onload = function() {
        clearTimeout(timeoutId);
        loading.style.display = 'none';
        refreshOverlay.style.display = 'none';
        iframe.style.display = 'block';
        viewerLoaded = true;
      };
      iframe.src = url;
    }

    function refreshViewer() {
      if (viewerLoaded) {
        refreshOverlay.style.display = 'flex';
      } else {
        loading.style.display = 'flex';
        iframe.style.display = 'none';
      }
      vscode.postMessage({ command: 'refresh' });
    }

    loadViewer(kwebUrl);

    document.getElementById('btn-export').addEventListener('click', function() {
      vscode.postMessage({ command: 'exportGds' });
    });

    document.getElementById('btn-refresh').addEventListener('click', function() {
      refreshViewer();
    });

    window.addEventListener('message', function(event) {
      var msg = event.data;
      if (msg.command === 'updateUrl') {
        loadViewer(msg.url);
      } else if (msg.command === 'refresh') {
        refreshViewer();
      }
    });
  })();
  </script>
</body>
</html>`;
  }

  private getUnavailableHtml(
    webview: vscode.Webview,
    fileName: string,
    message: string
  ): string {
    const nonce = getNonce();
    return /* html */ `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <meta http-equiv="Content-Security-Policy"
    content="default-src 'none'; style-src ${webview.cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}';"/>
  <title>${escapeHtml(fileName)}</title>
  <style>
    body {
      margin: 0;
      padding: 24px;
      font-family: var(--vscode-font-family, system-ui);
      color: var(--vscode-foreground, #ccc);
      background: var(--vscode-editor-background, #1e1e1e);
    }
    .card {
      max-width: 720px;
      margin: 40px auto;
      padding: 16px 18px;
      border: 1px solid var(--vscode-panel-border, #333);
      border-radius: 8px;
      background: var(--vscode-editorWidget-background, #252526);
    }
    .title {
      font-size: 14px;
      font-weight: 600;
      margin-bottom: 8px;
    }
    .message {
      color: var(--vscode-descriptionForeground, #aaa);
      line-height: 1.5;
      white-space: pre-wrap;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="title">kweb viewer unavailable for ${escapeHtml(fileName)}</div>
    <div class="message">${escapeHtml(message)}</div>
  </div>
</body>
</html>`;
  }
}

function getNonce(): string {
  let text = "";
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  for (let i = 0; i < 32; i++) {
    text += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return text;
}

function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
