import SwiftUI

/// The top bar's rotate button: portrait ⇄ landscape on an iPhone without
/// touching Portrait Orientation Lock. Shown only where iOS honours it
/// (`PlayerRotation.isOffered`), so never on an iPad, iPhone Duo's opened
/// inner display, the Mac or the TV. The icon shows where it goes. It fades
/// with the rest of the controls, and a press keeps them up for a moment so
/// the turned screen doesn't arrive bare.
struct PlayerRotateButton: View {
    let model: PlayerModel

    var body: some View {
        let lock = PlayerOrientationLock.shared
        if lock.offersRotation {
            let toPortrait = lock.interfaceOrientation.isLandscape
            PlayerCircleButton(
                systemName: toPortrait ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate",
                label: toPortrait ? "Rotate to portrait" : "Rotate to landscape"
            ) {
                lock.rotate()
                model.showControls()
            }
        }
    }
}
