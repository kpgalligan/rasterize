repo: kpgalligan/balopy-app
branch: main
path: app/Sources

## Last sync
date: 2026-08-09T14:19:05Z

### Updated in this project
- Added a Balopy-styled macOS design for the Rasterize editor window
- Menus, toolbar and key equivalents lifted verbatim from AppDelegate
- Layers panel, blend-mode groups and sheets matched to the Swift sources
- Proposed a no-document window and a Settings window (neither exists in the repo)

## Screen map
| Screen | Built from |
| --- | --- |
| Editing window | app/Sources/EditorViewController.swift, app/Sources/EditorWindowController.swift |
| Menus + toolbar | app/Sources/AppDelegate.swift, app/Sources/EditorWindowController.swift |
| Layers panel | app/Sources/LayersPanelViewController.swift, app/Sources/RasterCore.swift |
| Dialogs (Image Size, Canvas Size, Levels, Export) | app/Sources/Sheets.swift, app/Sources/ExportAccessoryController.swift |
| No document | app/Sources/AppDelegate.swift, app/Sources/FileDropView.swift |
| Settings | proposal — no repo source |
