# kweb GDS Viewer

A VS Code / Cursor extension that opens `.gds` and `.oas` layout files directly in the editor using [kweb](https://github.com/gdsfactory/kweb) as an embedded local server.

## Installation (gol-eda1 users)

Connect to `gol-eda1` via Cursor SSH and run a single command in the terminal:

```bash
/opt/tools/kweb-gds-viewer/install
```

That's it. The script will:

- Set up a Python environment with all required packages (no internet or root access needed)
- Install the Cursor extension automatically
- Configure the correct Python path so `.gds` files open immediately

After it completes, reload your Cursor window (**Ctrl+Shift+P → Developer: Reload Window**), then open any `.gds` or `.oas` file.

### Updating to a new version

Re-run the same command — it detects whether you're already current and only reinstalls when a newer version has been deployed:

```bash
/opt/tools/kweb-gds-viewer/install
```

---

## How it works

When you open a `.gds` or `.oas` file, the extension:

1. Locates a Python interpreter that has `kweb` and `uvicorn` installed.
2. Starts a local `uvicorn` ASGI server on port `8078` (kweb), pointed at the directory containing the file.
3. Renders the layout in a webview iframe that connects to the local server.

The server is shared across all open GDS files in the same directory and is stopped automatically when Cursor exits.

## Python discovery order

The extension searches for a suitable Python interpreter in this order:

1. `kweb-gds-viewer.kwebPythonPath` setting (if set).
2. `~/.local/share/kweb-gds-viewer/venv/bin/python` (created by the installer above).
3. `~/miniforge3/bin/python` and `~/mambaforge/bin/python` (common conda-forge installs).
4. The active environment from the [Python extension](https://marketplace.visualstudio.com/items?itemName=ms-python.python).
5. `python.defaultInterpreterPath` workspace setting.
6. `python3` / `python` on `PATH`.

Each candidate is probed for `import kweb.default, uvicorn` (kweb 2.x / 1.x) then `import kweb.main, uvicorn` (kweb 0.1.x legacy).

## Configuration

| Setting | Default | Description |
|---|---|---|
| `kweb-gds-viewer.kwebPythonPath` | `""` | Path to a Python executable with kweb + uvicorn. Overrides auto-discovery. |

Set this in `.vscode/settings.json` or in the VS Code settings UI if auto-discovery picks the wrong environment:

```json
{
  "kweb-gds-viewer.kwebPythonPath": "/path/to/your/env/bin/python"
}
```

## Commands

| Command | Description |
|---|---|
| **kweb GDS Viewer: Refresh GDS Viewer** | Restarts the kweb server and reloads the active viewer. |

The **Refresh** button in the editor title bar does the same thing.

## Remote-SSH

The extension works over Remote-SSH. It calls `vscode.env.asExternalUri` to tunnel the local kweb port through VS Code's port-forwarding mechanism, so the webview running on your laptop reaches the kweb server on the remote host automatically.

## Extension API

Other extensions can open GDS files or trigger a refresh programmatically:

```typescript
const api = vscode.extensions.getExtension('optocompiler.kweb-gds-viewer')?.exports;
await api?.openGds(uri);   // open a GDS file in the viewer
api?.refreshActive();       // refresh the currently active viewer
```

## Development

```bash
npm install
npm run build      # production bundle
npm run watch      # incremental rebuild while editing
npm run package:vsix  # produce a .vsix for local install
```

Source is in `src/`:

- `extension.ts` — activation entry point, exports the public API.
- `kwebServer.ts` — manages the uvicorn child process and health-checks.
- `gdsEditorProvider.ts` — custom editor provider and webview HTML.
