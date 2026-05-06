# Metal Composer

Metal Composer is a macOS node-based visual programming app for building realtime Metal shader compositions, audio-reactive visuals, 2D/3D scene experiments, OSC/MIDI-driven patches, and interactive graphics without having to manage separate Xcode projects for every idea.

The app combines a visual graph canvas, live renderer windows, editable Metal fragment nodes, preset video effects, image/video sources, audio analysis, MIDI/OSC, SceneKit-based 3D nodes, feedback loops, Gaussian splat experiments, and utility nodes for math, arrays, interaction, transforms, and layering.

## Features

- Node-based graph editor for building visual patches.
- Live Metal shader preview and render windows.
- Editable Metal fragment nodes with parsed inputs and persistent values.
- Preset shader/effect nodes including glitch, datamosh, prism split, ghost trails, frame melt, pixel sort, and procedural generators.
- Image, video, webcam, WebView, text, and AI image source nodes.
- Audio input, spectrum analysis, and beat detection nodes.
- MIDI output, MIDI input, and OSC send/receive helper nodes.
- 2D transform, billboard, line, layers, feedback, trail, iterator, array, and utility nodes.
- SceneKit 3D pipeline with primitives, text, model loading, materials, lights, particles, trackball/camera controls, and 3D scene rendering.
- Support for imported model files, textures, animated materials, and model animation playback.
- Gaussian splat PLY loading and panorama/depth pseudo-splat experiments.
- Realtime movie export from render windows.
- Graph saving/loading for reusable visual systems.

## Project Status

Metal Composer is an active experimental creative-coding project. It is being built as a personal visual prototyping environment inspired by tools like Quartz Composer, Vuo, TouchDesigner, Unity visual scripting, and shader graph workflows.

The project is still evolving quickly, so expect rough edges, unfinished nodes, graph compatibility changes, and ongoing architectural work as the 3D scene pipeline, material system, export tools, and media handling continue to grow.

## Requirements

- macOS with Metal support.
- Xcode for building from source.

## Building

Open `MetalNode.xcodeproj` in Xcode and run the `MetalNode` scheme. The built app appears as **Metal Composer**.

## Goal

The goal of Metal Composer is to make it fast and fun to prototype interactive visuals, shader effects, audio-reactive graphics, 3D scenes, feedback systems, and small creative tools inside one flexible node-based app.
