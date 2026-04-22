# Metal Composer

Metal Composer is a macOS node-based visual programming app for building real-time Metal shader compositions, audio-reactive visuals, 2D/3D scene experiments, and interactive graphics without having to manage separate Xcode projects for every idea.

The app combines a visual graph canvas, live renderer windows, editable Metal fragment nodes, preset video effects, image/video sources, audio analysis, MIDI output, SceneKit-based 3D nodes, feedback loops, and utility nodes for math, arrays, interaction, transforms, and layering.

## Features

- Node-based graph editor for building visual patches
- Live Metal shader preview and render windows
- Editable Metal fragment nodes with parsed inputs and persistent values
- Preset shader/effect nodes including glitch, datamosh, prism split, ghost trails, frame melt, pixel sort, and procedural generators
- Image, video, webcam, WebView, text, and AI image source nodes
- Audio input, spectrum analysis, and beat detection nodes
- MIDI output and MIDI CC support
- 2D transform, billboard, line, layers, feedback, trail, iterator, array, and utility nodes
- SceneKit 3D pipeline with primitives, text, model loading, materials, lights, particles, trackball/camera controls, and 3D scene rendering
- Support for imported model files, textures, animated materials, and model animation playback
- Graph saving/loading for reusable visual systems

## Project Status

Metal Composer is an active experimental creative-coding project. It is being built as a personal visual prototyping environment inspired by tools like Quartz Composer, Vuo, TouchDesigner, Unity visual scripting, and shader graph workflows.

The project is still evolving quickly, so expect rough edges, unfinished nodes, and ongoing architectural changes as the 3D scene pipeline, material system, export tools, and media handling continue to grow.

## Platform

- macOS
- SwiftUI
- Metal
- SceneKit
- AVFoundation
- Core Image

## Goal

The goal of Metal Composer is to make it fast and fun to prototype interactive visuals, shader effects, audio-reactive graphics, 3D scenes, feedback systems, and small creative tools inside one flexible node-based app.
