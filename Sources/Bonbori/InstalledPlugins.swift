// SPDX-License-Identifier: GPL-2.0-or-later
import BonboriPluginKit
import Captions
import Jikkyo

/// The plugins built into the app, the last one's overlays on top. This file is the only one that
/// names them.
let installedPlugins: [BonboriPlugin.Type] = [JikkyoPlugin.self, CaptionPlugin.self]
