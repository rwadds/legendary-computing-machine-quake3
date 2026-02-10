// SoundSystem.swift — AVAudioEngine-based sound mixing for Q3

import Foundation
import AVFoundation
import simd

class Q3SoundSystem {
    static let shared = Q3SoundSystem()

    // Audio engine
    private var audioEngine: AVAudioEngine?
    private var mixerNode: AVAudioMixerNode?

    // Sound channels
    private var channels: [SoundChannel] = []
    let maxChannels = 32

    // Registered sounds
    private var registeredSounds: [String: Int32] = [:]
    private var soundData: [Int32: SoundSample] = [:]
    private var nextSoundHandle: Int32 = 1

    // Listener
    var listenerOrigin: Vec3 = .zero
    var listenerForward: Vec3 = Vec3(1, 0, 0)
    var listenerRight: Vec3 = Vec3(0, 1, 0)
    var listenerUp: Vec3 = Vec3(0, 0, 1)

    // Volume
    var masterVolume: Float = 0.7
    var sfxVolume: Float = 0.7

    // State
    var initialized = false

    private init() {}

    // MARK: - Initialization

    func initialize() {
        guard !initialized else { return }

        audioEngine = AVAudioEngine()
        mixerNode = audioEngine?.mainMixerNode

        channels = (0..<maxChannels).map { _ in SoundChannel() }

        do {
            try audioEngine?.start()
            initialized = true
            Q3Console.shared.print("Sound system initialized")
        } catch {
            Q3Console.shared.warning("Failed to start audio engine: \(error)")
        }
    }

    func shutdown() {
        audioEngine?.stop()
        initialized = false
    }

    // MARK: - Registration

    func registerSound(_ name: String) -> Int32 {
        let key = name.lowercased()
        if let existing = registeredSounds[key] { return existing }

        let handle = nextSoundHandle
        nextSoundHandle += 1
        registeredSounds[key] = handle

        // Try to load the sound
        if let sample = SoundLoader.shared.loadSound(name) {
            soundData[handle] = sample
        }

        return handle
    }

    // MARK: - Play Sound

    func startSound(origin: Vec3?, entityNum: Int, channel: Int, sfxHandle: Int32) {
        guard initialized && sfxHandle > 0 else { return }

        // Find a free channel (or replace lowest priority)
        var bestChannel = -1
        for i in 0..<maxChannels {
            if !channels[i].playing {
                bestChannel = i
                break
            }
        }
        if bestChannel == -1 { bestChannel = 0 }  // Override first channel

        channels[bestChannel].playing = true
        channels[bestChannel].sfxHandle = sfxHandle
        channels[bestChannel].entityNum = entityNum
        channels[bestChannel].entChannel = channel
        channels[bestChannel].origin = origin ?? listenerOrigin
        channels[bestChannel].startTime = ProcessInfo.processInfo.systemUptime

        // Calculate spatialization
        spatialize(channelIdx: bestChannel)
    }

    func startLocalSound(_ sfxHandle: Int32, channelNum: Int) {
        startSound(origin: nil, entityNum: -1, channel: channelNum, sfxHandle: sfxHandle)
    }

    // MARK: - Spatialization

    private func spatialize(channelIdx: Int) {
        guard channelIdx >= 0 && channelIdx < maxChannels else { return }
        let ch = channels[channelIdx]

        let dir = ch.origin - listenerOrigin
        let dist = simd_length(dir)

        if dist < 1 {
            // At listener position: full volume both channels
            channels[channelIdx].leftVol = masterVolume * sfxVolume
            channels[channelIdx].rightVol = masterVolume * sfxVolume
            return
        }

        let normalDir = dir / dist
        let rightDot = simd_dot(normalDir, listenerRight)

        // Distance attenuation
        let maxDist: Float = 1250.0
        let attenuation = max(0, 1.0 - dist / maxDist)

        let vol = masterVolume * sfxVolume * attenuation
        channels[channelIdx].leftVol = vol * (1.0 - rightDot * 0.5)
        channels[channelIdx].rightVol = vol * (1.0 + rightDot * 0.5)
    }

    // MARK: - Update

    func update() {
        guard initialized else { return }

        let now = ProcessInfo.processInfo.systemUptime

        // Expire old sounds
        for i in 0..<maxChannels {
            guard channels[i].playing else { continue }

            // Check if sound is done (approximate duration of 2 seconds)
            if let sample = soundData[channels[i].sfxHandle] {
                let duration = Double(sample.numSamples) / Double(sample.sampleRate)
                if now - channels[i].startTime > duration {
                    channels[i].playing = false
                }
            } else {
                // No sample data, kill it
                channels[i].playing = false
            }
        }
    }

    // MARK: - Listener

    func updateListener(origin: Vec3, forward: Vec3, right: Vec3, up: Vec3) {
        listenerOrigin = origin
        listenerForward = forward
        listenerRight = right
        listenerUp = up
    }

    // MARK: - Looping Sounds

    func clearLoopingSounds() {
        // Stub
    }

    func addLoopingSound(entityNum: Int, origin: Vec3, velocity: Vec3, sfxHandle: Int32) {
        // Stub for looping ambient sounds
    }

    func stopLoopingSound(entityNum: Int) {
        guard initialized else { return }
    }

    func updateEntityPosition(entityNum: Int, origin: Vec3) {
        guard initialized else { return }
        // Update position for entity sounds
        for i in 0..<maxChannels {
            if channels[i].playing && channels[i].entityNum == entityNum {
                channels[i].origin = origin
                spatialize(channelIdx: i)
            }
        }
    }
}

// MARK: - Sound Channel

class SoundChannel {
    var playing = false
    var sfxHandle: Int32 = 0
    var entityNum: Int = -1
    var entChannel: Int = 0
    var origin: Vec3 = .zero
    var leftVol: Float = 0
    var rightVol: Float = 0
    var startTime: TimeInterval = 0
}
