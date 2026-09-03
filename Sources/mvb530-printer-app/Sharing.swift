/// Network sharing, as a switch in the web interface.
///
/// The page lives at /sharing: PAPPL reserves /network, /config, /security
/// and /logs for its own pages, and registering over one of those silently
/// yields a dead route.
///
/// Whether the printer is reachable from other machines is decided by which
/// addresses PAPPL binds, and that happens once at start-up - there is no API
/// to drop a listener later. So the choice is persisted here, read during
/// start-up, and changing it restarts the process. launchd brings it straight
/// back, so from the user's side it is a toggle that takes a few seconds.
import CPAPPL
import CPAPPLSupport
import Foundation

/// Sits beside PAPPL's own state file.
private let preferenceURL: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("mvb530-printer-app.sharing")
}()

/// Whether the printer should be reachable from other machines.
///
/// Defaults to false: PAPPL's web interface takes no authentication, so
/// joining a network should not hand everyone on it the ability to print or
/// to change settings.
func isSharingEnabled() -> Bool {
    if let raw = try? String(contentsOf: preferenceURL, encoding: .utf8) {
        return ["1", "true", "yes"].contains(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    return false
}

private func setSharingEnabled(_ enabled: Bool) {
    try? (enabled ? "1" : "0").write(to: preferenceURL, atomically: true,
                                     encoding: .utf8)
}

// MARK: - Web page

/// Registered once, from the driver callback, since that is where the system
/// pointer first becomes available.
private var sharingPageRegistered = false

func registerSharingPage(_ system: OpaquePointer?) {
    guard let system, !sharingPageRegistered else { return }
    sharingPageRegistered = true

    papplSystemAddResourceCallback(system, "/sharing", "text/html",
                                   sharingPage, UnsafeMutableRawPointer(system))
    papplSystemAddLink(system, "Sharing", "/sharing",
                       pappl_loptions_t(PAPPL_LOPTIONS_NAVIGATION.rawValue
                                        | PAPPL_LOPTIONS_CONFIGURATION.rawValue))
}

private let sharingPage: pappl_resource_cb_t = { client, data in
    guard let client else { return false }
    // Every PAPPL page starts here; without it the response is never begun
    // and the connection just closes.
    guard papplClientHTMLAuthorize(client) else { return true }
    let system = OpaquePointer(data)

    var banner: String?
    var restarting = false

    if papplClientGetMethod(client) == HTTP_STATE_POST {
        var form: UnsafeMutablePointer<cups_option_t>?
        let count = papplClientGetForm(client, &form)
        if count > 0, let form {
            let wanted = cupsGetOption("sharing", count, form)
                .map { String(cString: $0) } ?? "private"
            let enable = (wanted == "shared")

            if enable == isSharingEnabled() {
                banner = "No change - the printer is already "
                    + (enable ? "shared." : "private.")
            } else {
                setSharingEnabled(enable)
                restarting = true
                banner = enable
                    ? "Sharing turned on. Restarting to listen on the network."
                    : "Sharing turned off. Restarting to listen on this Mac only."
            }
        } else {
            banner = "Could not read the form."
        }
        cupsFreeOptions(count, form)
    }

    let shared = isSharingEnabled()

    // papplClientHTMLHeader writes the HTML <head>, not the HTTP response;
    // without this the body goes out headerless and clients report HTTP/0.9.
    guard papplClientRespond(client, HTTP_STATUS_OK, nil, "text/html", 0, 0)
    else { return true }

    // Reload after a restart so the page reflects the new state.
    papplClientHTMLHeader(client, "Sharing", restarting ? 8 : 0)
    if let banner {
        papplClientHTMLPuts(client,
            "<div class=\"banner\">" + banner + "</div>\n")
    }

    papplClientHTMLPuts(client, """
        <div class="content">
          <div class="row"><div class="col-12">
            <h1 class="title">Sharing</h1>
            <p>This printer connects over Bluetooth, so it is normally used
            from this Mac alone. Sharing also publishes it to the network you
            are joined to, so phones and tablets can print to it with this Mac
            relaying.</p>
            <p><b>The web pages you are reading have no password.</b> While
            sharing is on, anyone on the same network can print to the printer
            and change these settings, so leave it off unless you are on a
            network you trust.</p>
        """)

    papplClientHTMLPuts(client,
        "<p>Currently: <b>"
        + (shared ? "shared with the network" : "this Mac only")
        + "</b></p>\n")

    papplClientHTMLStartForm(client, "/sharing", false)
    papplClientHTMLPuts(client, """
        <table class="form">
          <tbody>
            <tr><th>Availability:</th><td>
              <select name="sharing">
        """)
    papplClientHTMLPuts(client,
        "<option value=\"private\"" + (shared ? "" : " selected")
        + ">This Mac only</option>"
        + "<option value=\"shared\"" + (shared ? " selected" : "")
        + ">Share with the network</option>")
    papplClientHTMLPuts(client, """
              </select>
            </td></tr>
            <tr><th></th><td><input type="submit" value="Save Changes"></td></tr>
          </tbody>
        </table>
        </form>
        <p>Saving restarts the printer service, which takes a few seconds.</p>
          </div></div>
        </div>
        """)
    papplClientHTMLFooter(client)

    // Shut down after the response has gone out; start-up then reads the new
    // preference to decide what to bind. launchd brings the service back when
    // it is installed as an agent; the .app has to ask for its own return.
    if restarting, let system {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            mvb_log(system, PAPPL_LOGLEVEL_INFO,
                    "restarting to apply the network setting")
            relaunchBundle(port: defaultIPPPort)
            papplSystemShutdown(system)
        }
    }
    return true
}
