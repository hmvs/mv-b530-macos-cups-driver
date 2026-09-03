/// How grey becomes black or white, as a page in the web interface.
///
/// The printer can only burn a dot or not, so every grey in a document has to
/// be decided one way or the other. Which way is a matter of taste as much as
/// correctness - solid rules against rules that read as grey - so it belongs
/// in front of the owner rather than in a file. Darkness is not repeated here:
/// PAPPL already offers it on the printer's own settings page.
///
/// Unlike sharing, these take effect on the next job. Nothing is bound to a
/// socket, so there is nothing to restart.
import CPAPPL
import CPAPPLSupport
import Foundation

private var qualityPageRegistered = false

func registerQualityPage(_ system: OpaquePointer?) {
    guard let system, !qualityPageRegistered else { return }
    qualityPageRegistered = true

    papplSystemAddResourceCallback(system, "/quality", "text/html",
                                   qualityPage, UnsafeMutableRawPointer(system))
    papplSystemAddLink(system, "Print quality", "/quality",
                       pappl_loptions_t(PAPPL_LOPTIONS_NAVIGATION.rawValue
                                        | PAPPL_LOPTIONS_CONFIGURATION.rawValue))
}

private let qualityPage: pappl_resource_cb_t = { client, _ in
    guard let client else { return false }
    guard papplClientHTMLAuthorize(client) else { return true }

    var banner: String?

    if papplClientGetMethod(client) == HTTP_STATE_POST {
        var form: UnsafeMutablePointer<cups_option_t>?
        let count = papplClientGetForm(client, &form)
        if count > 0, let form {
            let wanted = cupsGetOption("dither", count, form)
                .map { String(cString: $0) } ?? "auto"
            if ["auto", "diffuse", "threshold"].contains(wanted) {
                configuredDither = wanted
                setConfiguredValue("mvb530-dither", wanted)
            }

            if let raw = cupsGetOption("threshold", count, form),
               let value = Int(String(cString: raw)) {
                configuredThreshold = min(254, max(1, value))
                setConfiguredValue("mvb530-threshold", "\(configuredThreshold)")
            }
            banner = "Saved. The next page printed uses it."
        } else {
            banner = "Could not read the form."
        }
        cupsFreeOptions(count, form)
    }

    guard papplClientRespond(client, HTTP_STATUS_OK, nil, "text/html", 0, 0)
    else { return true }

    papplClientHTMLHeader(client, "Print quality", 0)
    if let banner {
        papplClientHTMLPuts(client, "<div class=\"banner\">" + banner + "</div>\n")
    }

    papplClientHTMLPuts(client, """
        <div class="content">
          <div class="row"><div class="col-12">
            <h1 class="title">Print quality</h1>
            <p>The printer burns a dot or leaves the paper blank, so every grey
            in a document has to become one or the other. Documents draw their
            borders and shading in grey far more often than in black, which is
            what these settings decide the fate of.</p>
        """)

    papplClientHTMLStartForm(client, "/quality", false)
    papplClientHTMLPuts(client, """
        <table class="form">
          <tbody>
            <tr><th>Greys:</th><td>
              <select name="dither">
        """)

    let options = [
        ("auto", "Solid lines, shaded photographs (recommended)"),
        ("diffuse", "Shade everything - greys print as grey"),
        ("threshold", "Solid everywhere - no shading at all"),
    ]
    for (value, label) in options {
        papplClientHTMLPuts(client,
            "<option value=\"" + value + "\""
            + (configuredDither == value ? " selected" : "") + ">"
            + label + "</option>")
    }

    papplClientHTMLPuts(client, """
              </select>
              <br><small>Shading renders a grey as a pattern of dots, which
              reads as grey but makes a thin rule dotted. Solid prints it as a
              full black line or not at all.</small>
            </td></tr>
        """)

    papplClientHTMLPuts(client, """
        <tr><th>Print greys darker than:</th><td>
          <input type="number" name="threshold" min="1" max="254" value="\(configuredThreshold)">
          <br><small>Out of 255, where 255 is blank paper. Documents commonly
          draw rules at 129, 145 and 160, so a setting below those loses them;
          much above 200 starts filling in the edges of letters. Only used
          where lines are printed solid.</small>
        </td></tr>
        """)

    papplClientHTMLPuts(client, """
            <tr><th></th><td><input type="submit" value="Save Changes"></td></tr>
          </tbody>
        </table>
        </form>
        <p>Darkness - how hard the head is driven - is on the printer's own
        settings page.</p>
          </div></div>
        </div>
        """)
    papplClientHTMLFooter(client)
    return true
}
