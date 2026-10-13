// Main screen: the full-screen stage and a small top bar. The bar never names
// the current shape; its name appears only inside the menu.

import SwiftUI

@main
struct ShapeSonicApp: App {
  @StateObject private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
    }
  }
}

struct StageView: UIViewRepresentable {
  let stage: Stage
  func makeUIView(context: Context) -> UIView { stage.container }
  func updateUIView(_ view: UIView, context: Context) {}
}

struct ContentView: View {
  @EnvironmentObject var model: AppModel
  @State private var menuOpen = false

  var body: some View {
    ZStack(alignment: .top) {
      StageView(stage: model.stage)
        .ignoresSafeArea()
      HStack(spacing: 12) {
        Button {
          model.engine.clearFingers()
          menuOpen = true
        } label: {
          Label("Menu", systemImage: "line.3.horizontal")
        }
        if let tracking = model.tracking {
          Text(tracking).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 8)
        Toggle(isOn: $model.showShape) {
          Label("Show shape", systemImage: model.showShape ? "eye" : "eye.slash")
        }
        .toggleStyle(.button)
        Button(action: model.recenter) {
          Label("Recenter", systemImage: "scope")
        }
      }
      .labelStyle(.iconOnly)
      .font(.title3)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.ultraThinMaterial, in: Capsule())
      .padding(.horizontal, 16)
      .padding(.top, 4)
    }
    .sheet(isPresented: $menuOpen) {
      MenuView().environmentObject(model)
    }
    .defersSystemGestures(on: .all)
    .persistentSystemOverlays(.hidden)
    .statusBarHidden()
    .onAppear {
      // The window (and so its screen) exists once the view is on screen.
      DispatchQueue.main.async { model.start() }
    }
  }
}
