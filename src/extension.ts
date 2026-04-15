import * as vscode from "vscode";
import { KwebServer } from "./kwebServer";
import { GdsEditorProvider } from "./gdsEditorProvider";

export interface KwebGdsViewerApi {
  openGds(uri: vscode.Uri): Promise<void>;
  refreshActive(): void;
}

export function activate(context: vscode.ExtensionContext): KwebGdsViewerApi {
  const kwebServer = new KwebServer();

  context.subscriptions.push(GdsEditorProvider.register(context, kwebServer));
  context.subscriptions.push({ dispose: () => kwebServer.dispose() });

  context.subscriptions.push(
    vscode.commands.registerCommand("kweb-gds-viewer.refreshGds", () => {
      GdsEditorProvider.refreshActive();
    })
  );

  return {
    openGds: async (uri: vscode.Uri): Promise<void> => {
      await vscode.commands.executeCommand(
        "vscode.openWith",
        uri,
        "kweb-gds-viewer.gdsEditor"
      );
    },
    refreshActive: (): void => {
      GdsEditorProvider.refreshActive();
    },
  };
}

export function deactivate(): void {
  // KwebServer is disposed via context.subscriptions
}
