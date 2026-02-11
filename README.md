# legendary-computing-machine-quake3
## quake3 ported to Swift

Converted https://github.com/id-Software/Quake-III-Arena to swift and Metal 4 to run on a Mac

## to run 
- clone, build in xcode
- download quake3-baseq3.zip (10-May-2024 06:21	604.7M) from here https://archive.org/download/quake3-baseq3
- unzip it and put the unzipped baseq3 dir  
- where mac.quake3 executable lives

### Key File
- once you unzip quake3-baseq3.zip you should look for pak0.pk3 which has the date Sunday, November 21, 1999 at 10:32 PM and file size 479,493,658 bytes (479.5 MB on disk)

## FPS
- Now Runs at ~45fps (asking for 120) but has 0 optimizations (see limitations below)
- Running on M4 Pro 2704x1384 composited

## Current limitations
- ~~has no collision detection + no gravity (it's like Minecraft creative mode) you fly everywhere and through walls~~
- ~~no weapons~~
- no bots spawning currently
- loopback network only
- ~~no jumping (see above)~~
- ~~no menu~~
- ~~one arena only~~

## Progress
- Renders arena using original pk3 files
- uses bytecode architecture of original source code https://github.com/id-Software/Quake-III-Arena
- runs on arm as the internal vm was designed to run on any os, any architecture

# Architecture

A native macOS port of Quake III Arena, written entirely in Swift with Metal 4 rendering. The engine runs the original QVM bytecode for game logic (`qagame.qvm`), client-game presentation (`cgame.qvm`), and UI menus (`ui.qvm`), communicating through syscall dispatch tables that mirror the original id Software API.

## High-Level Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        AppDelegate                               │
│                   GameViewController (Input)                     │
├──────────────────────────────────────────────────────────────────┤
│                         Q3Engine                                 │
│              (frame loop, subsystem coordinator)                 │
├───────────────┬──────────────────────────┬───────────────────────┤
│  ServerMain   │      ClientMain          │     Q3Console         │
│  (20 fps)     │      (variable fps)      │  Q3CommandBuffer      │
│               │                          │  Q3CVar               │
├───────┬───────┼──────┬───────────────────┼───────────────────────┤
│ Game  │Server │CGame │  ClientUI         │   Q3FileSystem        │
│  VM   │ World │ VM   │   (UI VM)         │    (PK3 archives)     │
├───────┴───────┼──────┴───────────────────┼───────────────────────┤
│  Collision    │      RenderMain          │   Q3SoundSystem       │
│  Model        │  (Metal 4, BSP, shaders) │   MusicPlayer         │
├───────────────┼──────────────────────────┼───────────────────────┤
│  BotLib       │      NetManager          │   QVM Interpreter     │
│  BotAAS/AI    │      (loopback)          │   (bytecode runtime)  │
└───────────────┴──────────────────────────┴───────────────────────┘
```

## Execution Flow

### Startup

1. `AppDelegate.applicationDidFinishLaunching()` → `Q3Engine.shared.initialize()`
2. Engine registers core CVars, initializes `Q3FileSystem` (loads all `.pk3` files)
3. Executes `default.cfg`, `q3config.cfg`, `autoexec.cfg` via `Q3CommandBuffer`
4. `GameViewController.viewDidLoad()` creates `MTKView` and `RenderMain`

### Map Load (`map q3dm1`)

1. `Q3Engine.startMap()` → `RenderMain.loadMap()` parses BSP, builds GPU geometry
2. `ServerMain.spawnServer()` → loads collision model, initializes world sectors, loads `qagame.qvm`
3. Server runs 3 settle frames to let game VM initialize entities
4. `ClientMain.connectLocal()` → receives gamestate, loads `cgame.qvm`, calls `cgInit`

### Frame Loop (`Q3Engine.frame()`)

```
Q3Engine.frame(msec)
├── Q3CommandBuffer.executeBuffer()          // deferred console commands
├── ClientMain → ServerMain (loopback)       // transfer usercmd
├── ServerMain.frame(msec)                   // fixed 20fps timestep
│   ├── gameVM::gameRunFrame()               // physics, AI, spawns
│   ├── read client commands                 // usercmd processing
│   └── build + send snapshots               // entity state to client
└── ClientMain.frame(msec)                   // variable timestep
    ├── parse server messages                // snapshot unpacking
    ├── build UserCmd from input             // keyboard/mouse → cmd
    ├── predict player movement              // client-side Pmove
    ├── cgameVM::cgFrame()                   // interpolation, effects
    │   └── syscalls: addRefEntity, addLight, addPoly, renderScene
    └── RenderMain.draw()                    // GPU submission
```

---

## Subsystems

### Engine Core

| File | Purpose |
|------|---------|
| `Engine/Q3Engine.swift` | Singleton coordinator — init, frame loop, map loading, crash handler |
| `Engine/Q3Types.swift` | `EntityState`, `PlayerState`, `UserCmd`, `TraceResult`, `GameState` |
| `Engine/Q3Constants.swift` | `MAX_CLIENTS` (64), `MAX_GENTITIES` (1024), `PROTOCOL_VERSION` (68), surface/content flags |
| `Engine/MathLib.swift` | Vector math, `angleVectors()`, `perpendicular(to:)`, angle conversion |
| `Engine/MessageBuffer.swift` | Network message read/write (bytes, shorts, ints, floats, strings, angles) |

### QVM Virtual Machine

| File | Purpose |
|------|---------|
| `VM/QVM.swift` | Loads `.qvm` files — parses header, code segment, data segment, builds instruction pointer table |
| `VM/QVMInterpreter.swift` | Stack-based bytecode interpreter — 60 opcodes, syscall dispatch on negative CALL targets |
| `VM/QVMTypes.swift` | Syscall enums (`GameImport`, `GameExport`, `CGImport`, `CGExport`, `UIImport`, `UIExport`) |

Three VM instances run simultaneously:
- **qagame.qvm** — server-side game logic (entity spawning, physics callbacks, item rules)
- **cgame.qvm** — client-side presentation (entity interpolation, effects, HUD)
- **ui.qvm** — menu system (main menu, server browser, settings)

Calling convention (matches ioquake3 `vm_interpreted.c`):
- **CALL**: write return address at `PS+0`, no stack adjustment
- **ENTER**: `PS -= locals`
- **LEAVE**: `PS += locals`, read return address from `PS+0`
- **Syscall**: negative call target triggers host dispatch; args at `PS+4` (syscall num), `PS+8` (arg1), `PS+12` (arg2), ...

### Server

| File | Purpose |
|------|---------|
| `Server/ServerMain.swift` | Server lifecycle, entity arrays (`gentities[1024]`), config strings, 20fps frame accumulator |
| `Server/ServerGame.swift` | Game VM syscall dispatch — 50+ syscalls (print, cvars, file I/O, collision, sound, entity linking) |
| `Server/ServerWorld.swift` | Spatial partitioning (64 area nodes), area queries for entity linking |
| `Server/ServerClient.swift` | Per-client state (`SVClient`), connection handshake, command processing |
| `Server/ServerSnapshot.swift` | Snapshot ring buffer — delta-compressed entity state sent to clients |

The server ticks at a fixed 20fps (`frameMsec=50`). Each tick: run game VM frame → process client commands → build snapshots → send to clients.

### Client

| File | Purpose |
|------|---------|
| `Client/ClientMain.swift` | Connection state machine, snapshot ring buffer, cgame VM lifecycle |
| `Client/ClientGame.swift` | CGame VM syscall dispatch — 86 syscalls (renderer, sound, prediction, snapshots) |
| `Client/ClientInput.swift` | Keyboard/mouse → `UserCmd` (angle encoding, movement clamping) |
| `Client/ClientSnapshot.swift` | Snapshot unpacking, entity baseline delta decoding |
| `Client/ClientPredict.swift` | Client-side movement prediction via `Pmove` (gravity=800, jump=270, maxSpeed=320) |
| `Client/ClientUI.swift` | UI VM syscall dispatch — 88 imports (menus, key bindings, renderer forwarding) |
| `Client/RendererAPI.swift` | Builds refdef (view parameters) for renderer from cgame output |

Connection states: `disconnected` → `connecting` → `connected` → `loading` → `primed` → `active`

### Renderer (Metal 4)

| File | Purpose |
|------|---------|
| `Render/RenderMain.swift` | `MTKViewDelegate` — camera, frustum, draw dispatch, Metal 4 objects |
| `Render/RenderBSP.swift` | PVS + frustum culling, surface collection, shader-batched multi-stage rendering |
| `Render/RenderEntity.swift` | MD3 model rendering, sprites, beams |
| `Render/RenderSky.swift` | Skybox rendering |
| `Render/RenderLight.swift` | Dynamic light accumulation |
| `Render/RenderEffects.swift` | Particle systems, polygon marks |
| `Render/MetalPipelineManager.swift` | Pipeline state cache keyed by blend mode + depth/alpha test |
| `Render/BSPGeometryBuilder.swift` | Converts BSP surfaces to GPU vertex/index buffers |
| `Render/LightmapAtlas.swift` | Packs 128x128 lightmap tiles into atlas texture |
| `Render/TextureCache.swift` | Texture loading and GPU caching |
| `Render/ImageLoader.swift` | TGA/PNG image parsing |
| `Render/BezierPatch.swift` | Bezier patch tessellation to triangle meshes |
| `Shaders.metal` | `q3VertexShader` / `q3FragmentShader` — transforms, multi-stage blending, tcMod, rgbGen |

Metal 4 specifics:
- `MTL4CommandQueue` / `MTL4CommandBuffer` with triple-buffered command allocators
- `MTL4ArgumentTable` for vertex/fragment resource binding (buffers + textures)
- `MTLResidencySet` for VRAM texture management
- `MTLSharedEvent` for frame synchronization
- Blend state via `colorAttachment.blendingState = .enabled`
- Indexed drawing with `MTLGPUAddress` (not `MTLBuffer`)

Render pipeline per frame:
1. Update camera from cgame refdef (or free-fly)
2. Compute 4 frustum planes
3. Walk BSP tree with PVS cluster visibility + frustum test → visible surface list
4. Sort surfaces by shader, iterate stages per shader
5. Per stage: evaluate `rgbGen`/`alphaGen`/`tcMod` → compute `Q3StageUniforms` → bind pipeline + textures → draw
6. Render entities (MD3 interpolation between frames)
7. Render sky, effects
8. Present drawable

### Shader System

| File | Purpose |
|------|---------|
| `Render/ShaderParser.swift` | Parses `scripts/*.shader` files from PK3 archives into `Q3ShaderDef` objects |
| `Render/Q3Shader.swift` | `Q3ShaderDef` and `ShaderStage` data structures |
| `Render/ShaderEval.swift` | Runtime evaluation — wave tables (1024 entries), tcMod application, per-stage uniform computation |

Each `Q3ShaderDef` contains one or more `ShaderStage` objects:
- **rgbGen**: identity, wave, entity, vertex, lightingDiffuse, exactVertex, oneMinusVertex
- **alphaGen**: identity, entity, wave, portal
- **tcMod**: scroll, scale, rotate, stretch, turb, transform
- **tcGen**: texture, lightmap, environment, fog, vector
- **blendMode**: source/dest blend factors (GL-style)
- **alphaTest**: GT0, LT128, GE128
- **deformVertexes**: wave, normals, bulge, move, autosprite, autosprite2

### BSP & Collision

| File | Purpose |
|------|---------|
| `Model/BSPFile.swift` | BSP v46 parser — 17 lumps (entities, planes, nodes, leafs, surfaces, lightmaps, visibility, brushes, etc.) |
| `Model/BSPModel.swift` | Runtime world model — PVS queries, leaf lookup, surface collection |
| `Model/CollisionModel.swift` | AABB trace through BSP brush geometry, point contents queries |
| `Model/MD3Model.swift` | MD3 format — frames, surfaces (meshes), tags (attachment points) |

### Networking

| File | Purpose |
|------|---------|
| `Net/NetManager.swift` | Loopback driver for single-player — synchronous message queues |
| `Net/NetChannel.swift` | Sequence numbers, reliable/unreliable message channels |

Currently loopback-only (single-player). Client and server run in the same process, exchanging messages through `NetManager`'s in-memory queues.

### File System

| File | Purpose |
|------|---------|
| `FileSystem/FileSystem.swift` | `Q3FileSystem` singleton — virtual file system over PK3 search paths |
| `FileSystem/PK3File.swift` | ZIP reader using Apple Compression framework (COMPRESSION_ZLIB) |

Loads `baseq3/pak0.pk3` through `pak8.pk3` plus `q3wpak0-4.pk3` in sorted order (higher numbers override). File lookup is cached for fast access. Provides file handle API for QVM syscalls (`openFileRead`, `readFile`, `writeFile`, `closeFile`).

### Console & CVars

| File | Purpose |
|------|---------|
| `Console/Console.swift` | `Q3Console` — 1024-line text buffer, 4 notification lines (3s display), scroll |
| `Console/CVar.swift` | `Q3CVar` registry — name/value/flags, modification tracking, latched values |
| `Console/CommandBuffer.swift` | `Q3CommandBuffer` — command queue, tokenization (argc/argv), handler dispatch |

CVar flags: `archive`, `userInfo`, `serverInfo`, `systemInfo`, `initOnly`, `latch`, `rom`, `cheat`.

### Sound

| File | Purpose |
|------|---------|
| `Sound/SoundSystem.swift` | `Q3SoundSystem` — AVAudioEngine mixing, 32 channels, 3D spatialization |
| `Sound/SoundLoader.swift` | WAV parsing, resampling to 44100 Hz, sound cache |
| `Sound/MusicPlayer.swift` | `AVAudioPlayer` for background music (`music/trackNN.mp3/ogg/wav`) |

### Bot System

| File | Purpose |
|------|---------|
| `Bot/BotLib.swift` | Master dispatcher — core (200-211), AAS (300-318), EA (400-427), AI (500-589) |
| `Bot/BotAAS.swift` | Area Awareness System — loads `.aas` files, simplified pathfinding |
| `Bot/BotAI.swift` | Character traits from skill level, handle allocation for chat/move/goal/weapon |
| `Bot/BotChat.swift` | Chat queue with hardcoded templates (death, kill, greeting, taunt) |

### Input

Handled in `GameViewController.swift`:
- `NSEvent` monitoring for key/mouse events
- Mouse capture via `CGAssociateMouseAndMouseCursorPosition`
- WASD + mouse look → `ClientInput` → `UserCmd`
- Backtick toggles console, Escape releases mouse

---

## Key Data Structures

```
EntityState        — network entity: number, type, flags, position trajectory,
                     angles, modelindex, frame, clientNum, events, weapon, anim

PlayerState        — player: origin, velocity, viewangles, stats[16], persistant[16],
                     powerups[16], ammo[16], weaponTime, gravity, speed, pm_flags

UserCmd            — input: serverTime, angles (SIMD3<Int32>), buttons, forwardmove,
                     rightmove, upmove

TraceResult        — collision: allSolid, startSolid, fraction, endPos, plane,
                     surfaceFlags, contents, entityNum

Q3ShaderDef        — material: name, stages[], sort, cull, deforms[], surfaceFlags

ShaderStage        — render pass: rgbGen, alphaGen, tcMod[], blendMode, alphaTest,
                     depthWrite, textureBundles[]

GameState          — config strings[1024], entity baselines
```

## File Listing

```
mac.quake3/
├── AppDelegate.swift
├── GameViewController.swift
├── Renderer.swift
├── Shaders.metal
├── ShaderTypes.h
├── Engine/
│   ├── Q3Engine.swift
│   ├── Q3Types.swift
│   ├── Q3Constants.swift
│   ├── MathLib.swift
│   └── MessageBuffer.swift
├── Console/
│   ├── Console.swift
│   ├── CVar.swift
│   └── CommandBuffer.swift
├── FileSystem/
│   ├── FileSystem.swift
│   └── PK3File.swift
├── VM/
│   ├── QVM.swift
│   ├── QVMInterpreter.swift
│   └── QVMTypes.swift
├── Server/
│   ├── ServerMain.swift
│   ├── ServerGame.swift
│   ├── ServerWorld.swift
│   ├── ServerClient.swift
│   └── ServerSnapshot.swift
├── Client/
│   ├── ClientMain.swift
│   ├── ClientGame.swift
│   ├── ClientInput.swift
│   ├── ClientSnapshot.swift
│   ├── ClientPredict.swift
│   ├── ClientUI.swift
│   └── RendererAPI.swift
├── Render/
│   ├── RenderMain.swift
│   ├── RenderBSP.swift
│   ├── RenderSky.swift
│   ├── RenderEntity.swift
│   ├── RenderLight.swift
│   ├── RenderEffects.swift
│   ├── MetalPipelineManager.swift
│   ├── MetalBufferPool.swift
│   ├── BSPGeometryBuilder.swift
│   ├── LightmapAtlas.swift
│   ├── TextureCache.swift
│   ├── ImageLoader.swift
│   ├── BezierPatch.swift
│   ├── Q3Shader.swift
│   ├── ShaderParser.swift
│   └── ShaderEval.swift
├── Model/
│   ├── BSPFile.swift
│   ├── BSPModel.swift
│   ├── CollisionModel.swift
│   └── MD3Model.swift
├── Net/
│   ├── NetManager.swift
│   └── NetChannel.swift
├── Sound/
│   ├── SoundSystem.swift
│   ├── SoundLoader.swift
│   └── MusicPlayer.swift
└── Bot/
    ├── BotLib.swift
    ├── BotAAS.swift
    ├── BotAI.swift
    └── BotChat.swift
```

