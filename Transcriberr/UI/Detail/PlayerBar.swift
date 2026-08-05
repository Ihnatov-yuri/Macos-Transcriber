import SwiftUI

/// Editorial player bar. Plain (no rounded corners), mono time label,
/// 1.5dp accent progress, tap-to-seek.
struct PlayerBar: View {
    let recording: Recording
    @Environment(AppContainer.self) private var container

    var body: some View {
        HStack(spacing: AppMetric.m) {
            TapButton {
                container.audioPlayer.toggle()
            } label: {
                // Drawn shapes, not text glyphs: U+258C/U+25B6 aren't in the
                // display font, and the fallback renders full-em black slabs.
                Group {
                    if container.audioPlayer.isPlaying {
                        HStack(spacing: 3) {
                            Rectangle().frame(width: 3, height: 12)
                            Rectangle().frame(width: 3, height: 12)
                        }
                    } else {
                        PlayTriangle()
                            .frame(width: 11, height: 12)
                    }
                }
                .foregroundStyle(AppColor.ink)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }


            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    waveformTrack(width: geo.size.width)
                    // Playhead line
                    Rectangle()
                        .fill(AppColor.ink)
                        .frame(width: 1)
                        .offset(x: geo.size.width * progress)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let frac = max(0, min(1, location.x / geo.size.width))
                    container.audioPlayer.seek(to: frac * container.audioPlayer.duration)
                }
            }
            .frame(height: 28)

            Text("\(timeStamp(container.audioPlayer.currentTime)) / \(timeStamp(container.audioPlayer.duration))")
                .monoLabel(10, color: AppColor.inkSoft)
                .monospacedDigit()
        }
        .padding(.horizontal, AppMetric.sheetPadding)
        .padding(.vertical, 10)
        .background(AppColor.paperEdge)
        .task(id: recording.id) {
            container.audioPlayer.load(url: URL(fileURLWithPath: recording.audioPath))
        }
    }

    /// 200-bucket peak waveform with split-color rendering (past = accent,
    /// future = soft ink). Falls back to a plain 2 px progress bar until the
    /// peaks have been extracted.
    @ViewBuilder
    private func waveformTrack(width: CGFloat) -> some View {
        let peaks = container.audioPlayer.waveform
        if peaks.isEmpty {
            VStack {
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    Rectangle().fill(AppColor.hairline)
                    Rectangle().fill(AppColor.accent).frame(width: width * progress)
                }
                .frame(height: 2)
                Spacer(minLength: 0)
            }
        } else {
            // Downsample to the available width (≥3 pt per bar) — 200 fixed
            // bars have a ~400 pt minimum intrinsic width and overflow the
            // track in narrow panes.
            let barCount = max(10, min(peaks.count, Int(width / 3)))
            let sampled: [Float] = (0 ..< barCount).map { i in
                peaks[Int(Double(i) * Double(peaks.count) / Double(barCount))]
            }
            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(sampled.enumerated()), id: \.offset) { idx, peak in
                    let played = Double(idx) / Double(barCount) <= progress
                    Capsule()
                        .fill(played ? AppColor.accent : AppColor.inkFaint)
                        .frame(width: max(1, (width - CGFloat(barCount - 1)) / CGFloat(barCount)),
                               height: max(2, CGFloat(peak) * 26))
                }
            }
            .frame(maxWidth: width, alignment: .leading)
        }
    }

    /// Small solid triangle for the play state.
    private struct PlayTriangle: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }

    private var progress: Double {
        guard container.audioPlayer.duration > 0 else { return 0 }
        return container.audioPlayer.currentTime / container.audioPlayer.duration
    }

    private func timeStamp(_ s: Double) -> String {
        let total = Int(s.isFinite ? s : 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
