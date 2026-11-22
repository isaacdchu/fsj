import SwiftUI

/// Three tabs: Record, Stats, Settings.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Record", systemImage: "record.circle", value: AppTab.record) {
                RecordView()
            }
            Tab("Camera", systemImage: "video", value: AppTab.camera) {
                CameraView()
            }
            Tab("Stats", systemImage: "chart.bar", value: AppTab.stats) {
                StatsView()
            }
            Tab("Settings", systemImage: "slider.horizontal.3", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(Palette.text)
    }
}

#Preview("Light") {
    ContentView()
        .environment(AppModel.preview())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ContentView()
        .environment(AppModel.preview())
        .preferredColorScheme(.dark)
}
