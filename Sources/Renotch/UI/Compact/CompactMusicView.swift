import SwiftUI

struct CompactMusicView: View {
    @ObservedObject var music: MusicService
    @ObservedObject var timer: TimerService
    let message: String?
    var showsTrackInfo = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            AlbumArtworkView(artwork: music.artwork, cornerRadius: 6, fallbackSource: music.activeSource)
                .frame(width: 24, height: 24)
                .overlay(alignment: .bottomLeading) {
                    MusicSourceBadge(source: music.activeSource, size: 10)
                        .padding(1.5)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                .animation(.easeOut(duration: 0.2), value: music.activeSource)

            if showsTrackInfo {
                VStack(alignment: .leading, spacing: 1) {
                    Text(message ?? music.track?.title ?? "Music")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(message == nil ? .white : Color.notchAccent)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(Color.notchMuted)
                        .lineLimit(1)
                }
                .transition(.opacity)
            }

            Spacer(minLength: 6)

            if timer.isActive {
                // Apple Dynamic Island Live Timer Pill
                HStack(spacing: 4.5) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: timer.progress)
                            .stroke(
                                timer.currentMode.tint,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.25), value: timer.progress)
                        Image(systemName: timer.isPaused ? "pause.fill" : timer.currentMode.icon)
                            .font(.system(size: 5.5, weight: .bold))
                            .foregroundStyle(timer.currentMode.tint)
                    }
                    .frame(width: 12, height: 12)

                    Text(TimerService.formatted(timer.remaining))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timer.currentMode.tint)
                        .fixedSize()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(timer.currentMode.tint.opacity(0.12))
                )
                .overlay(
                    Capsule()
                        .stroke(timer.currentMode.tint.opacity(0.22), lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .animation(.snappy(duration: 0.25), value: timer.isActive)
            } else if isHovered {
                HStack(spacing: 5) {
                    Button {
                        music.previousTrack()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 17, height: 17)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Previous Track")

                    Button {
                        music.togglePlayback()
                    } label: {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(music.isPlaying ? "Pause" : "Play")

                    Button {
                        music.nextTrack()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 17, height: 17)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Next Track")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                )
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                AudioWaveform(isPlaying: music.isPlaying, barCount: 6)
                    .frame(width: 24, height: 11)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.18), value: showsTrackInfo)
    }

    private var subtitle: String {
        if let artist = music.track?.artist, !artist.isEmpty {
            return "\(artist) · \(music.activeSource.displayName)"
        }
        switch music.playbackState {
        case .notRunning: return "Apple Music, Spotify or QQ Music"
        case .stopped: return "Not playing"
        case .paused: return "Paused"
        case .playing: return "Now playing"
        }
    }
}
