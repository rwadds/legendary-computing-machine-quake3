# legendary-computing-machine-quake3
## quake3 ported to Swift

Converted https://github.com/id-Software/Quake-III-Arena to swift and Metal 4 to run on a Mac

## to run 
- clone, build in xcode
- download quake3-baseq3.zip (10-May-2024 06:21	604.7M) from here https://archive.org/download/quake3-baseq3
- unzip it and put the unzipped baseq3 dir  
- where mac.quake3 executable lives

## FPS
- Runs at ~100fps (asking for 120) but has 0 optimizations
- Running on M4 Pro 2704x1384 composited

## Current limitations
- has no collision detection (it's like Minecraft creative mode) you fly everywhere
- no weapons
- no bots spawning currently
- loopback network only
- no jumping (see above)
