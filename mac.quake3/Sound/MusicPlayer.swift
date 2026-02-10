// MusicPlayer.swift — Background music track playback for Q3

import Foundation
import AVFoundation

class Q3MusicPlayer {
    static let shared = Q3MusicPlayer()

    private var player: AVAudioPlayer?
    private var currentTrack: String = ""
    var musicVolume: Float = 0.5
    var enabled = true

    private init() {}

    // MARK: - Track Playback

    func startBackgroundTrack(_ introTrack: String, _ loopTrack: String) {
        guard enabled else { return }

        let trackToPlay = introTrack.isEmpty ? loopTrack : introTrack
        guard !trackToPlay.isEmpty else {
            stopBackgroundTrack()
            return
        }

        // Don't restart same track
        if trackToPlay == currentTrack && player?.isPlaying == true {
            return
        }

        currentTrack = trackToPlay

        // Try to load from pk3 filesystem
        let paths = musicPaths(for: trackToPlay)
        for path in paths {
            if let data = Q3FileSystem.shared.loadFile(path) {
                playData(data, loop: !loopTrack.isEmpty)
                return
            }
        }

        Q3Console.shared.print("Music: couldn't find track \(trackToPlay)")
    }

    func stopBackgroundTrack() {
        player?.stop()
        player = nil
        currentTrack = ""
    }

    // MARK: - Volume

    func setVolume(_ vol: Float) {
        musicVolume = max(0, min(1, vol))
        player?.volume = musicVolume
    }

    // MARK: - Playback

    private func playData(_ data: Data, loop: Bool) {
        do {
            player = try AVAudioPlayer(data: data)
            player?.volume = musicVolume
            player?.numberOfLoops = loop ? -1 : 0
            player?.prepareToPlay()
            player?.play()
        } catch {
            Q3Console.shared.print("Music: playback error: \(error)")
        }
    }

    private func musicPaths(for name: String) -> [String] {
        var paths: [String] = []

        // Try as-is first
        paths.append(name)

        // Add music/ prefix if not present
        let baseName: String
        if name.hasPrefix("music/") {
            baseName = name
        } else {
            baseName = "music/\(name)"
            paths.append(baseName)
        }

        // If no extension, try common formats
        if !name.contains(".") {
            for ext in ["ogg", "mp3", "wav"] {
                paths.append("\(baseName).\(ext)")
                paths.append("\(name).\(ext)")
            }
        }

        return paths
    }

    // MARK: - State

    var isPlaying: Bool {
        return player?.isPlaying ?? false
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        if player != nil && !isPlaying {
            player?.play()
        }
    }
}
