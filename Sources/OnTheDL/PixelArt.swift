import SwiftUI

/// Tiny sprites drawn from character grids. Each character maps to a palette color; "." is transparent.
struct Sprite: View {
    let rows: [String]
    let palette: [Character: Color]
    var scale: CGFloat = 3

    var body: some View {
        let w = rows.map(\.count).max() ?? 0
        Canvas { ctx, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = palette[ch] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)), with: .color(c))
                }
            }
        }
        .frame(width: CGFloat(w) * scale, height: CGFloat(rows.count) * scale)
        .accessibilityHidden(true)
    }
}

/// On The DL's logo: a down arrow keeping a low profile behind a pair of shades.
struct Logo: View {
    var pixel: CGFloat = 3

    static let rows = [
        "....kkkkkkkk....",
        "....kyyyyyyk....",
        "....kyyyyyyk....",
        "kkkkkkkkkkkkkkkk",
        ".kkwwkkkkkwwkkk.",
        ".kkkwkkyykkwkkk.",
        "..kkkkkyykkkkk..",
        "....kyyyyyyk....",
        "kkkkkyykkkyykkkk",
        ".kyyyyyyyyyyyyk.",
        "..kyyyyyyyyyyk..",
        "...kyyyyyyyyk...",
        "....kyyyyyyk....",
        ".....kyyyyk.....",
        "......kyyk......",
        ".......kk.......",
    ]

    var body: some View {
        Sprite(rows: Self.rows, palette: ["k": Pixel.edge, "y": Pixel.yellow, "w": Pixel.cyan], scale: pixel)
            .accessibilityLabel("On The DL")
    }
}

enum Sprites {
    static let k = Pixel.edge

    static func check(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            ".......kk",
            "......kgk",
            ".....kggk",
            "kk..kggk.",
            "kgkkggk..",
            "kgggggk..",
            ".kgggk...",
            "..kkk....",
        ], palette: ["k": k, "g": Pixel.green], scale: scale)
    }

    static func moon(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            "..kkkk..",
            ".kiik...",
            "kiik....",
            "kiik....",
            "kiiik...",
            "kiiiikkk",
            ".kiiiiik",
            "..kkkkk.",
        ], palette: ["k": k, "i": Pixel.ice], scale: scale)
    }

    static func skull(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            ".kkkkkk.",
            "kwwwwwwk",
            "kwkkwkkk",
            "kwkkwkkk",
            "kwwwwwwk",
            ".kwkwkk.",
            ".kkkkkk.",
        ], palette: ["k": k, "w": Pixel.red], scale: scale)
    }
}
