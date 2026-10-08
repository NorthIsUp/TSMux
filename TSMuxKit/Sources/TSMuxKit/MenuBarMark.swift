#if canImport(AppKit)
  import AppKit

  public enum MenuBarMark {
    /// The menu bar mark: a 3x3 dot grid with the top-middle dot promoted to a
    /// chevron — Tailscale's family resemblance, plus the thing tsmux adds,
    /// which is traffic leaving through several tailnets at once. Filled dots
    /// count the connected tailnets, so the mark carries the state a "2/3"
    /// badge used to. Drawn rather than an asset: it changes with the count,
    /// and a template image tints itself in both menu bar appearances.
    public static func image(lit litRaw: CGFloat, total: Int) -> NSImage {
      let size = NSSize(width: 18, height: 14)
      let image = NSImage(size: size, flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        // The same multiplexer the app icon uses: tailnets on either side, each
        // on its own line, converging on one hub. A spoke is lit when that many
        // tailnets are connected, so the mark counts without any text.
        let hub = CGPoint(x: 9, y: 7)
        let cols: [CGFloat] = [2.4, 15.6]
        let rows: [CGFloat] = [2.4, 7, 11.6]
        let node: CGFloat = 1.5
        let hubR: CGFloat = 2.0

        var slots: [(CGFloat, CGFloat)] = []
        for y in rows { for x in cols { slots.append((x, y)) } }
        slots.sort { a, b in a.1 == b.1 ? a.0 < b.0 : a.1 < b.1 }
        let dimAll = total == 0
        let lit = max(0, min(litRaw, CGFloat(slots.count)))

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(1.35)
        for (i, p) in slots.enumerated() {
          // Fractional, so a spoke brightens through the intermediate values
          // instead of stepping: `lit` of 1.4 has spoke 0 full and spoke 1 at
          // 40%. The dot is the tailnet, the line is just its route: keep every
          // dot legible so the mark always reads as a full mux, and let the
          // unlit lines recede rather than disappear.
          let on = dimAll ? 0 : max(0, min(lit - CGFloat(i), 1))
          let lineAlpha = 0.26 + 0.74 * on
          let dotAlpha = 0.5 + 0.5 * on
          ctx.setStrokeColor(NSColor.black.withAlphaComponent(lineAlpha).cgColor)
          ctx.beginPath()
          ctx.move(to: CGPoint(x: p.0, y: p.1))
          if abs(p.1 - hub.y) < 0.01 {
            ctx.addLine(to: hub)
          } else {
            // The app icon's bezier at menu bar scale: a smooth S with strongly
            // horizontal tangents, so the trace runs flat out of the dot and
            // arrives flat at the hub with one bend between.
            let reach = (hub.x - p.0) * 0.62
            ctx.addCurve(
              to: hub,
              control1: CGPoint(x: p.0 + reach, y: p.1),
              control2: CGPoint(x: hub.x - reach, y: hub.y))
          }
          ctx.strokePath()
          ctx.setFillColor(NSColor.black.withAlphaComponent(dotAlpha).cgColor)
          ctx.fillEllipse(
            in: CGRect(x: p.0 - node, y: p.1 - node, width: node * 2, height: node * 2))
        }

        // Two spare channels straight up and down, always dim: capacity the hub
        // has that nothing is plugged into. Same as the app icon, so the two
        // marks read as one thing.
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.26).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        for y in [rows[0], rows[2]] {
          ctx.beginPath()
          ctx.move(to: CGPoint(x: hub.x, y: y))
          ctx.addLine(to: hub)
          ctx.strokePath()
          ctx.fillEllipse(
            in: CGRect(x: hub.x - node, y: y - node, width: node * 2, height: node * 2))
        }

        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAll ? 0.3 : 1).cgColor)
        ctx.fillEllipse(
          in: CGRect(x: hub.x - hubR, y: hub.y - hubR, width: hubR * 2, height: hubR * 2))
        return true
      }
      image.isTemplate = true
      return image
    }
  }
#endif
