"use strict";
// Owner browser only: no localStorage, no token in URLs, no telemetry/logging.
window.addEventListener("load", async () => {
    const button = document.getElementById("choose");
    const status = document.getElementById("status");
    const report = message => { status.textContent = message; };
    let configuration;
    try {
        const response = await fetch("/admin/folder/config", {credentials: "same-origin", cache: "no-store"});
        if (!response.ok) throw new Error();
        configuration = await response.json();
        await new Promise((resolve, reject) => {
            if (!window.gapi) { reject(new Error()); return; }
            gapi.load("picker", {callback: resolve, onerror: reject, timeout: 15000, ontimeout: reject});
        });
        button.disabled = false;
        report("Choose only the specified backup folder. This setup session expires after ten minutes.");
    } catch {
        report("Setup could not load. Check the server's Picker key/project configuration and authorize again at /admin.");
        return;
    }
    button.addEventListener("click", () => {
        const view = new google.picker.DocsView(google.picker.ViewId.FOLDERS)
            .setIncludeFolders(true).setSelectFolderEnabled(true)
            .setMimeTypes("application/vnd.google-apps.folder")
            .setMode(google.picker.DocsViewMode.LIST);
        const picker = new google.picker.PickerBuilder()
            .addView(view).setOAuthToken(configuration.accessToken)
            .setDeveloperKey(configuration.apiKey).setAppId(configuration.appId)
            .setOrigin(window.location.origin)
            .setCallback(async data => {
                if (data[google.picker.Response.ACTION] !== google.picker.Action.PICKED) return;
                const docs = data[google.picker.Response.DOCUMENTS] || [];
                if (docs.length !== 1 || docs[0][google.picker.Document.ID] !== configuration.targetFolderId) {
                    report("That is not the required folder. Select ID " + configuration.targetFolderId + ".");
                    return;
                }
                button.disabled = true;
                report("Checking write permission with Google Drive…");
                try {
                    const response = await fetch("/admin/folder/confirm", {
                        method: "POST", credentials: "same-origin", cache: "no-store",
                        headers: {"Content-Type": "application/json", "X-Focal-CSRF": configuration.csrf},
                        body: JSON.stringify({folderId: configuration.targetFolderId})
                    });
                    if (!response.ok || !(await response.json()).verified) throw new Error();
                    configuration = null;
                    picker.dispose();
                    report("Folder access and add-file permission verified. Use the owner CLI to invite each device. Upload completion still requires a verified test capture.");
                } catch {
                    button.disabled = false;
                    report("Drive could not confirm access. Check the selected account and folder permissions, then retry or authorize again.");
                }
            }).build();
        picker.setVisible(true);
    });
});
