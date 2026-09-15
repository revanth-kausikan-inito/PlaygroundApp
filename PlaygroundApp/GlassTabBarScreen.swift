import SwiftUI

struct GlassTabBarScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GlassTabBarController {
        GlassTabBarController()
    }

    func updateUIViewController(_ uiViewController: GlassTabBarController, context: Context) {}
}
