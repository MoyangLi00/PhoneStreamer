import SwiftUI

struct ContentView: View {
    @StateObject private var streamer = StreamManager()

    var body: some View {
        ZStack {
            CameraPreviewView(session: streamer.previewSession)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Text(streamer.status)
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.55))
                            .foregroundColor(.white)
                            .cornerRadius(10)

                        Text("Frames: \(streamer.frameCount)")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55))
                            .foregroundColor(.white)
                            .cornerRadius(10)

                        Text("IMU: \(streamer.imuCount)")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .padding()

                Spacer()

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        TextField("Mac IP", text: $streamer.host)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                        TextField("Port", value: $streamer.port, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .frame(width: 100)
                    }

                    HStack(spacing: 16) {
                        Button("Start") {
                            streamer.start()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Stop") {
                            streamer.stop()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }
}

#Preview {
    ContentView()
}
