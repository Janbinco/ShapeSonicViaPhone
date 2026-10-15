// The pop-up menu: shape choice and loading, display toggles, hand mode,
// feature threshold, sound, latency options, placement and screen calibration.

import SwiftUI

struct MenuView: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var importing = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(model.demos) { demo in
            Button {
              model.select(demo)
            } label: {
              HStack {
                Text(demo.name.capitalized)
                Spacer()
                if model.shapeName == demo.name { Image(systemName: "checkmark") }
              }
            }
          }
          Button("Load model…") { importing = true }
          Toggle("Fit loaded models to 40 cm", isOn: $model.fitTo40cm)
          HStack(alignment: .firstTextBaseline) {
            if model.loading { ProgressView().padding(.trailing, 4) }
            Text(model.status)
              .font(.footnote)
              .foregroundStyle(model.statusIsError ? .red : .secondary)
          }
        } header: {
          Text("Shape")
        } footer: {
          Text("OBJ, PLY, STL, USDZ/USD or Alembic. The shape should be closed (watertight).")
        }

        Section {
          if AppModel.glassModeAvailable {
            Picker("Input", selection: $model.inputMode) {
              ForEach(InputMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!HandTracker.isSupported && model.inputMode == .glass)
          }
          if model.inputMode == .air {
            Text(model.airStatus.text).font(.footnote).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
              Text(String(format: "Shape centre: %.0f cm from the screen", model.airDistance * 100))
              Slider(value: $model.airDistance, in: 0.2...0.6, step: 0.01)
            }
            VStack(alignment: .leading) {
              Text(String(format: "Shape size: %.0f cm", model.airSize * 100))
              Slider(value: $model.airSize, in: 0.08...0.4, step: 0.01)
            }
            Toggle("Smooth fingertips", isOn: $model.airSmoothing)
            Button("Level and recenter the shape", action: model.recenter)
          }
        } header: {
          Text("Input")
        } footer: {
          if !HandTracker.isSupported {
            Text("Hands in the air needs a TrueDepth (Face ID) camera.")
          } else if model.inputMode == .air {
            Text("Stand the phone up facing you, or lay it flat with the screen up. "
                 + "The front camera tracks both hands; each fingertip plays its own note "
                 + "(thumb C, index D, middle E, ring G, little A). The shape is placed in front of the screen "
                 + "and stays fixed in the room; recenter to bring it back.")
          } else if HandTracker.isSupported {
            Text("Touch the glass: move the phone through the shape. "
                 + "Hands in the air: keep the phone still and reach into the shape in front of it.")
          } else {
            Text("Hands in the air needs a TrueDepth (Face ID) camera.")
          }
        }

        Section("Display") {
          Toggle("Show shape", isOn: $model.showShape)
          Toggle("Show edges and corners", isOn: $model.showFeatures).disabled(!model.showShape)
        }

        if model.inputMode == .glass {
        Section {
          Picker("Hands", selection: $model.handMode) {
            ForEach(HandMode.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
        } header: {
          Text("Hands")
        } footer: {
          Text(model.handMode == .split
               ? "A touch belongs to the left hand if it starts on the left half of the screen."
               : "The first five touches are the left hand and the next five the right hand.")
            + Text(model.engine.screenGeometry.isIPad ? "" : " iPhone screens track at most five touches at once.")
        }
        }

        Section {
          VStack(alignment: .leading) {
            Text("Sharp edge angle: \(Int(model.sharpAngle))°")
            Slider(value: $model.sharpAngle, in: 5...120, step: 1) { editing in
              if !editing { model.sharpAngleCommitted() }
            }
          }
        } header: {
          Text("Edges and corners")
        } footer: {
          Text("An edge is sharp where its faces meet at more than this angle.")
        }

        Section {
          HStack {
            Image(systemName: "speaker.fill")
            Slider(value: $model.volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
          }
          Toggle("Vibrate when crossing the surface", isOn: $model.vibrateOnCrossing)
            .disabled(!model.haptics.isSupported)
        } header: {
          Text("Sound and touch")
        } footer: {
          Text(model.haptics.isSupported
               ? "A sharp tap when a fingertip enters the shape, a softer one when it leaves."
               : "This device has no Taptic Engine.")
        }

        Section {
          if model.inputMode == .glass {
            Toggle("Predict device motion", isOn: $model.predictMotion)
            Toggle("Use predicted touches", isOn: $model.predictTouches)
          }
          Text(model.latencyText).font(.footnote).foregroundStyle(.secondary)
        } header: {
          Text("Latency")
        } footer: {
          Text((model.inputMode == .glass
                ? "Motion prediction brings the camera pose forward to now with the gyroscope. " : "")
               + "Wired headphones or the speaker are much faster than Bluetooth (150–300 ms).")
        }

        if model.inputMode == .glass {
        Section("Placement") {
          Button("Place in front of me", action: model.recenter)
          if model.stage.isAR {
            Button("Place on surface at screen centre", action: model.placeOnSurface)
            if let message = model.surfaceMessage {
              Text(message).font(.footnote).foregroundStyle(.secondary)
            }
          } else {
            VStack(alignment: .leading) {
              Text(String(format: "Virtual device moved forward %.0f cm", model.virtualAdvance * 100))
              Slider(value: $model.virtualAdvance, in: 0...0.9)
            }
          }
        }

        }

        if model.inputMode == .glass {
        Section {
          Text(model.screenText)
          Stepper(value: $model.ppiOverride, in: 0...600, step: 1) {
            Text(model.ppiOverride > 0 ? "Override: \(Int(model.ppiOverride)) ppi" : "Override: off")
          }
        } header: {
          Text("Screen")
        } footer: {
          Text("Touches are placed on the glass using the screen's pixel density. "
               + "Override it only if this device isn't recognised.")
        }
        }
      }
      .navigationTitle("ShapeSonic")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: AppModel.importTypes) { result in
        if case .success(let url) = result { model.importFile(url) }
      }
    }
  }
}
