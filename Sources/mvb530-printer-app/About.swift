/// An About page, because the menu bar item alone explains very little.
///
/// PAPPL builds its own menu - system name, version, printers, Quit - and
/// there is no hook to add to it. Clicking the name opens the web interface,
/// so that is where an explanation can go.
import CPAPPL
import CPAPPLSupport
import Foundation

private var aboutPageRegistered = false

func registerAboutPage(_ system: OpaquePointer?) {
    guard let system, !aboutPageRegistered else { return }
    aboutPageRegistered = true

    papplSystemAddResourceCallback(system, "/about", "text/html",
                                   aboutPage, UnsafeMutableRawPointer(system))
    papplSystemAddLink(system, "About", "/about",
                       pappl_loptions_t(PAPPL_LOPTIONS_NAVIGATION.rawValue))
}

private let aboutPage: pappl_resource_cb_t = { client, _ in
    guard let client else { return false }
    guard papplClientHTMLAuthorize(client) else { return true }
    guard papplClientRespond(client, HTTP_STATUS_OK, nil, "text/html", 0, 0)
    else { return true }

    papplClientHTMLHeader(client, "About", 0)
    papplClientHTMLPuts(client, """
        <div class="content">
          <div class="row"><div class="col-12">
            <h1 class="title">Anko Inkless A4</h1>
            <p>This is a printer driver. It lets macOS print to the Kmart
            <b>Anko Inkless A4</b> thermal printer (sold as MV-B530, and as
            GL-VS9, QDID and X9), which otherwise only works from the vendor's
            phone app - its USB-C port carries power and nothing else.</p>

            <p>It runs as a small background app that presents the printer to
            macOS as an ordinary network printer and talks to the hardware over
            Bluetooth LE. Print to <b>Anko Inkless A4</b> from any app; switch
            the printer on first, or the job waits for it.</p>

            <h2 class="title">Settings</h2>
            <p><a href="/sharing">Sharing</a> decides whether other devices on
            your network can print to it. It is off by default.</p>
            <p>The port, how long a job waits for a sleeping printer, and which
            unit to use are read from
            <code>~/Library/Application&nbsp;Support/Anko&nbsp;Inkless&nbsp;A4.conf</code>.</p>

            <h2 class="title">Where it came from</h2>
            <p>The printer speaks no standard protocol, so its wire format was
            reverse-engineered. Open source, MIT licensed:
            <a href="https://github.com/hmvs/mv-b530-macos-cups-driver">github.com/hmvs/mv-b530-macos-cups-driver</a>.</p>
          </div></div>
        </div>
        """)
    papplClientHTMLFooter(client)
    return true
}
