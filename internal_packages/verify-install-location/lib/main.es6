const {dialog} = require('electron').remote
import {ipcRenderer} from 'electron'

/**
 * We want to make sure that people have installed the app in a
 * reasonable location.
 *
 * On the Mac, you can accidentally run the app from the DMG. If you do
 * this, it will no longer auto-update. It's also common for Mac users to
 * leave their app in the /Downloads folder (which frequently gets
 * erased!).
 */

function onNotificationActionTaken(numAsks) {
  return (buttonIndex) => {
    if (buttonIndex === 0) {
      ipcRenderer.send("move-to-applications")
    }

    if (numAsks >= 1) {
      if (buttonIndex === 1) {
        NylasEnv.config.set("asksAboutAppMove", 5)
      } else {
        NylasEnv.config.set("asksAboutAppMove", numAsks + 1)
      }
    } else {
      NylasEnv.config.set("asksAboutAppMove", numAsks + 1)
    }
  }
}

export function activate() {
  if (NylasEnv.inDevMode() || NylasEnv.inSpecMode()) { return; }

  if (process.platform !== "darwin") { return; }

  const appRe = /Applications/gi;
  if (appRe.test(process.argv[0])) { return; }

  // If we're in Volumes, that means we've launched from the DMG. This
  // is unsupported. We should optimistically move.
  const volTest = /Volumes/gi;
  if (volTest.test(process.argv[0])) {
    ipcRenderer.send("move-to-applications");
    return;
  }

  const numAsks = NylasEnv.config.get("asksAboutAppMove")
  if (numAsks >= 5) return;

  let buttons;
  if (numAsks >= 1) {
    buttons = [
      "Move to Applications folder",
      "Don't ask again",
      "Do not move",
    ]
  } else {
    buttons = [
      "Move to Applications folder",
      "Do not move",
    ]
  }

  let msg = `We recommend that you move N1 to your Applications folder to get updates correctly and keep this folder uncluttered.`

  const CANCEL_ID = 3;

  dialog.showMessageBox({
    type: "question",
    buttons: buttons,
    title: "A Better Place to Install N1",
    message: "Move to Applications folder?",
    detail: msg,
    defaultId: 0,
    cancelId: CANCEL_ID,
  }, onNotificationActionTaken(numAsks))
}

export function deactivate() {
}
