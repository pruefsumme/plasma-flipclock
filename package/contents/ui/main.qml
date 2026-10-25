pragma ComponentBehavior: Bound

/*
 * main.qml — the Plasma applet wrapper.
 *
 * This is the only file that knows about Plasma. It sources the time and feeds
 * strings to FlipClock.qml, which is plain QtQuick so the render harness can
 * load it standalone.
 */
import QtQuick
import QtQuick.Layouts

import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.clock
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

import "Style.js" as S

PlasmoidItem {
    id: root

    // Initial default size only. The desktop containment (via
    // ContainmentLayoutManager.AppletsLayout + BasicAppletContainer) owns the
    // actual geometry and persists user resizes in plasma-org.kde.plasma.
    // desktop-appletsrc under ItemGeometries-<W>x<H>. Size hints flow through
    // the Layout attached properties on the fullRepresentation below, which the
    // container reads and binds into its own Layout.preferredWidth/Height.
    //
    // Each dimension's binding MUST be independent of the other. The desktop
    // containment restores saved geometry by re-applying it through the Layout
    // pathway during startup; a cross-binding like `height: width * ratio` (or
    // `Layout.preferredHeight: Layout.preferredWidth * ratio`) re-fires when
    // the paired property is restored and silently clobbers the just-restored
    // value, snapping the widget back to its default size every restart.
    //
    // The containment's saved geometry is keyed by screen resolution and can
    // miss at boot, so we also keep the last size in our own config.
    width: Plasmoid.configuration.widgetWidth > 0
            ? Plasmoid.configuration.widgetWidth
            : Kirigami.Units.gridUnit * 28
    height: Plasmoid.configuration.widgetHeight > 0
             ? Plasmoid.configuration.widgetHeight
             : Kirigami.Units.gridUnit * 28 * S.REF_H / S.REF_W

    // Skip the startup relayout, then save resizes once they settle.
    Timer {
        id: startupGuard
        interval: 5000
        running: true
    }
    Timer {
        id: saveSize
        interval: 1000
        onTriggered: {
            if (root.width > 0 && root.height > 0) {
                Plasmoid.configuration.widgetWidth = Math.round(root.width)
                Plasmoid.configuration.widgetHeight = Math.round(root.height)
            }
        }
    }
    onWidthChanged: if (!startupGuard.running) saveSize.restart()
    onHeightChanged: if (!startupGuard.running) saveSize.restart()

    // The widget draws its own skeuomorphic body, so no Plasma frame behind it;
    // ConfigurableBackground still lets the user switch one back on.
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground | PlasmaCore.Types.ConfigurableBackground
    preferredRepresentation: fullRepresentation

    toolTipMainText: Qt.formatTime(clock.dateTime, Qt.locale().timeFormat(Locale.ShortFormat))
    toolTipSubText: Qt.formatDate(clock.dateTime, Qt.locale().dateFormat(Locale.LongFormat))

    // Plasma 6.7's native clock. trackSeconds:false gives minute-resolution
    // updates aligned to the minute boundary by the C++ side -- exactly what a
    // flip clock wants, since the flip should fire ON the boundary.
    Clock {
        id: clock
        trackSeconds: false
    }

    // Leaving timeZone unset makes Clock follow the system zone, so only bind it
    // when the user has actually chosen one.
    Binding {
        target: clock
        property: "timeZone"
        value: Plasmoid.configuration.timeZone
        when: Plasmoid.configuration.timeZone !== ""
        restoreMode: Binding.RestoreBindingOrValue
    }

    function pad(n) {
        return n < 10 ? "0" + n : "" + n
    }

    readonly property string hourString: {
        let h = clock.dateTime.getHours()
        if (!Plasmoid.configuration.use24hFormat) {
            h = h % 12
            if (h === 0)
                h = 12
        }
        // A blank leading tile reads better than a zero on a physical flip clock,
        // but the original padded, so it stays the default.
        return Plasmoid.configuration.showLeadingZero ? pad(h) : (h < 10 ? " " + h : "" + h)
    }

    readonly property string minuteString: pad(clock.dateTime.getMinutes())

    // Plasma5Support is part of a normal Plasma Desktop install. Its weather
    // engine lets us use the providers distributed by the system without a
    // dependency on KWeather or an external web API.
    readonly property string configuredWeatherSource: Plasmoid.configuration.weatherSource.trim()
    readonly property string discoveredWeatherSource: {
        for (const source of weather.sources) {
            if (source.indexOf("|weather|") !== -1)
                return source
        }
        return ""
    }
    readonly property string weatherSource: {
        if (Plasmoid.configuration.weatherUseAutomaticSource
                && discoveredWeatherSource.length > 0)
            return discoveredWeatherSource
        return configuredWeatherSource
    }
    // DataSource.valid is not a bindable Qt property in Plasma 6.  Do not use
    // it in this expression: it would evaluate false at startup and prevent the
    // weather UI from ever seeing the first provider update.  The revision is
    // advanced by newData below, which makes this binding reliably reactive.
    property int weatherRevision: 0
    readonly property var weatherData: {
        const revision = weatherRevision
        return weatherSource.length > 0 ? weather.data[weatherSource] : null
    }

    function weatherText(field) {
        if (!weatherData || weatherData[field] === undefined || weatherData[field] === null)
            return ""
        return String(weatherData[field])
    }

    function degreeText(value) {
        const text = value === undefined || value === null
                   ? "" : String(value).trim()
        if (text.length === 0 || text.indexOf("°") !== -1
                || !/[0-9]/.test(text))
            return text
        // Some ions (notably DWD) expose observations as floating-point
        // values. Stringifying one directly leaks its binary representation
        // into the UI (for example 18.79999237060547°). Keep one meaningful
        // decimal place, matching the forecast values supplied by the engine.
        const number = Number(value)
        if (isFinite(number)) {
            const rounded = Math.round(number * 10) / 10
            const precision = Math.abs(rounded - Math.round(rounded)) < 0.00001
                              ? 0 : 1
            return Qt.locale().toString(rounded, "f", precision) + "°"
        }
        return text + "°"
    }

    function shortPlace(value) {
        const text = value === undefined || value === null
                   ? "" : String(value).trim()
        const comma = text.indexOf(",")
        return comma === -1 ? text : text.substring(0, comma).trim()
    }

    // The legacy engine's forecast contract is
    // period|icon|summary|high|low|precipitation. A few ions also publish
    // convenient top-level high/low fields, so prefer those and fall back to
    // day zero. Empty slots are significant (for example Tonight has no high).
    readonly property var weatherToday: weatherText("Short Forecast Day 0").split("|")
    readonly property string weatherHighRaw: {
        const direct = weatherText("High Temperature")
        return direct.length > 0 ? direct
                                 : (weatherToday.length > 3 ? weatherToday[3] : "")
    }
    readonly property string weatherLowRaw: {
        const direct = weatherText("Low Temperature")
        return direct.length > 0 ? direct
                                 : (weatherToday.length > 4 ? weatherToday[4] : "")
    }
    readonly property string weatherHigh: degreeText(weatherHighRaw) || "--"
    readonly property string weatherLow: degreeText(weatherLowRaw) || "--"
    readonly property string weatherRange: "H: " + weatherHigh + "\nL: " + weatherLow
    // Wettercom may publish only its day-zero forecast summary/icon, rather
    // than a current-observation field. The legacy forecast contract supplies
    // both, so use it before showing an unavailable placeholder.
    readonly property string weatherCondition: {
        const current = weatherText("Current Conditions")
        return current.length > 0 ? current
                                  : (weatherToday.length > 2 ? weatherToday[2] : "--")
    }
    readonly property string weatherIcon: {
        const current = weatherText("Condition Icon")
        return current.length > 0 ? current
                                  : (weatherToday.length > 1 && weatherToday[1].length > 0
                                     ? weatherToday[1] : "weather-clear-night")
    }

    function refreshWeather() {
        const source = root.weatherSource
        if (source.length === 0)
            return

        // Reconnecting a DataEngine source causes the provider to publish its
        // current data immediately instead of waiting for the 30-minute poll.
        weather.disconnectSource(source)
        weather.connectSource(source)
    }

    Plasma5Support.DataSource {
        id: weather
        engine: "weather"
        // "ions" reports the locally installed providers. It also keeps the
        // engine alive so an already-active compatible source can be found.
        connectedSources: root.weatherSource.length > 0 ? ["ions", root.weatherSource] : ["ions"]
        interval: 30 * 60 * 1000
        onNewData: function(sourceName, data) {
            ++root.weatherRevision
        }
    }

    fullRepresentation: Item {
        // Independent bindings (see root width/height comment). The desktop
        // containment reads these Layout attached properties via
        // BasicAppletContainer to negotiate the widget's size; cross-bindings
        // here are the more likely restart-reset pathway because the container
        // binds its own Layout.preferredWidth to max(Layout.minimumWidth,
        // Layout.preferredWidth) of this item.
        Layout.minimumWidth: Kirigami.Units.gridUnit * 10
        Layout.minimumHeight: Kirigami.Units.gridUnit * 10 * S.REF_H / S.REF_W
        Layout.preferredWidth: Plasmoid.configuration.widgetWidth > 0
                ? Plasmoid.configuration.widgetWidth
                : Kirigami.Units.gridUnit * 28
        Layout.preferredHeight: Plasmoid.configuration.widgetHeight > 0
                ? Plasmoid.configuration.widgetHeight
                : Kirigami.Units.gridUnit * 28 * S.REF_H / S.REF_W

        FlipClock {
            anchors.fill: parent

            hours: root.hourString
            minutes: root.minuteString
            animate: Plasmoid.configuration.animationsEnabled

            showPanel: Plasmoid.configuration.showPanel
            showStrips: Plasmoid.configuration.showDateStrip

            dateText: Plasmoid.configuration.showDateStrip
                      ? Qt.formatDate(clock.dateTime, Plasmoid.configuration.dateFormat)
                      : ""
            alarmText: Plasmoid.configuration.rightStripText

            // Weather remains visible even before a location is selected or a
            // provider responds. This makes the enabled state explicit and
            // gives every missing provider field a stable, intentional value.
            hasWeather: Plasmoid.configuration.showWeather
            // Some ions omit Place from otherwise valid weather updates. Keep
            // the selected location visible instead of rendering a blank slot;
            // an unconfigured widget gets an equally clear placeholder.
            wxLocation: root.shortPlace(root.weatherText("Place").length > 0
                        ? root.weatherText("Place")
                        : Plasmoid.configuration.weatherLocation) || i18n("Unknown City")
            wxCondition: root.weatherCondition
            wxTemperature: root.degreeText(root.weatherText("Temperature")) || "--"
            wxRange: root.weatherRange
            wxIcon: root.weatherIcon
            wxVariationKey: Qt.formatDate(clock.dateTime, "yyyy-MM-dd")
                            + "|" + wxLocation

            onWeatherRefreshRequested: root.refreshWeather()
        }
    }
}
