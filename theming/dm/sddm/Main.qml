import QtQuick
import QtQuick.Effects

Rectangle {
    id: root
    width: 1280
    height: 800
    color: cfgS("bg", "#000000")

    // ── config helpers (SDDM config values arrive as strings) ─────────
    function cfgS(k, d) { var v = config[k]; return (v === undefined || v === null || v === "") ? d : String(v) }
    function cfgN(k, d) { var v = parseFloat(cfgS(k, "")); return isNaN(v) ? d : v }
    function cfgB(k, d) { var v = cfgS(k, ""); return v === "" ? d : (v === "true" || v === "1") }

    // scale is in physical pixels; dividing by the window's pixel ratio keeps
    // sizes identical whether Qt runs unscaled (Weston) or scaled (preview
    // window under Hyprland)
    readonly property real s: cfgN("scale", 1.0) / Screen.devicePixelRatio
    readonly property color cBg: cfgS("bg", "#000000")
    readonly property color cFg: cfgS("fg", "#dfdfdf")
    readonly property color cAccent: cfgS("accent", "#5EA4B8")
    readonly property color cWrong: cfgS("wrong", "#cc241d")
    readonly property string fontName: cfgS("font", "monospace")
    readonly property real clockSize: cfgN("clockSize", 104) * s
    readonly property real fieldH: cfgN("fieldHeight", 55) * s
    readonly property real fieldGap: 12 * s

    // idle | verify | fail
    property string state_: "idle"

    // ── users / sessions ─────────────────────────────────────────────
    property int userIdx: Math.max(0, userModel.lastIndex)
    property int sessionIdx: Math.max(0, sessionModel.lastIndex)
    Repeater { id: users; model: userModel; delegate: Item { required property string name } }
    Repeater { id: sessions; model: sessionModel; delegate: Item { required property string name } }
    function userAt(i) { return users.count > 0 && users.itemAt(i) ? users.itemAt(i).name : "" }
    readonly property string sessionName: sessions.count > 0 && sessions.itemAt(sessionIdx) ? sessions.itemAt(sessionIdx).name : ""

    function doLogin() {
        if (state_ === "verify") return
        if (userField.input.text === "") { userField.input.forceActiveFocus(); return }
        state_ = "verify"
        if (cfgB("preview", false)) previewTimer.start()
        else sddm.login(userField.input.text, pwField.input.text, sessionIdx)
    }
    function fail() { state_ = "fail"; pwField.input.text = ""; pwField.input.forceActiveFocus() }

    Timer { id: previewTimer; interval: 900; onTriggered: root.fail() }
    Connections {
        target: sddm
        function onLoginFailed() { root.fail() }
        function onLoginSucceeded() { root.state_ = "idle" }
    }

    Keys.onEscapePressed: if (cfgB("preview", false)) Qt.quit()

    // ── background: wallpaper, blurred + dimmed (hyprlock background{}) ──
    Image {
        id: wall
        anchors.fill: parent
        source: cfgS("background", "") === "" ? "" : "file://" + cfgS("background", "")
        fillMode: Image.PreserveAspectCrop
        visible: false
    }
    MultiEffect {
        anchors.fill: parent
        source: wall
        visible: wall.status === Image.Ready
        blurEnabled: cfgB("blur", true)
        blur: 0.6
        blurMax: 48
        saturation: cfgN("vibrancy", 0.2)
    }
    Rectangle { anchors.fill: parent; color: "black"; opacity: 1.0 - cfgN("dim", 0.5); visible: wall.status === Image.Ready }

    // ── clock + date (hyprlock label{} x2, y is up-positive there) ────
    property date now: new Date()
    Timer { interval: 1000; running: true; repeat: true; onTriggered: root.now = new Date() }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -180 * s
        text: Qt.formatTime(root.now, "HH:mm:ss")
        color: cFg
        font.family: fontName
        font.pixelSize: clockSize
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -100 * s
        text: Qt.formatDate(root.now, "dddd, MMMM dd, yyyy")
        color: cFg
        font.family: fontName
        font.pixelSize: clockSize / 3
    }

    // ── input field (hyprlock input-field{}) ─────────────────────────
    component Field: Rectangle {
        id: f
        property alias input: ti
        property bool secret: false
        property string placeholder: ""
        property bool failed: false
        signal submit()
        signal next()
        signal prev()

        width: cfgN("fieldWidth", 300) * s
        height: fieldH
        anchors.horizontalCenter: parent.horizontalCenter
        radius: cfgN("rounding", 2) * s
        color: cBg
        border.width: cfgN("border", 2) * s
        border.color: failed ? cWrong : cAccent
        opacity: ti.activeFocus ? 1.0 : 0.75
        Behavior on border.color { ColorAnimation { duration: 150 } }

        TextInput {
            id: ti
            anchors.fill: parent
            anchors.margins: f.border.width + 8 * s
            horizontalAlignment: TextInput.AlignHCenter
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            color: cFg
            selectionColor: cAccent
            font.family: fontName
            font.pixelSize: f.height * 0.3
            echoMode: TextInput.Normal
            // secret fields draw their own dots below, like hyprlock
            opacity: f.secret ? 0 : 1
            enabled: root.state_ !== "verify"
            Keys.onReturnPressed: f.submit()
            Keys.onEnterPressed: f.submit()
            Keys.onTabPressed: f.next()
            Keys.onDownPressed: f.next()
            Keys.onBacktabPressed: f.prev()
            Keys.onUpPressed: f.prev()
            Keys.onEscapePressed: if (cfgB("preview", false)) Qt.quit()
            onTextChanged: if (f.secret && text.length > 0 && root.state_ === "fail") root.state_ = "idle"
        }

        Text {
            anchors.centerIn: parent
            width: parent.width - 2 * parent.border.width - 8 * s
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            visible: ti.text.length === 0
            text: f.placeholder
            color: f.failed ? cWrong : cFg
            opacity: root.state_ === "idle" || !f.secret ? 0.6 : 1.0
            font.family: fontName
            font.pixelSize: f.height * 0.3
        }

        Row {
            anchors.centerIn: parent
            visible: f.secret
            readonly property real dot: (f.height - 2 * f.border.width) * 0.33
            spacing: dot * 0.5
            Repeater {
                model: f.secret ? Math.min(ti.text.length, Math.floor((f.width * 0.8) / (parent.dot * 1.5))) : 0
                Rectangle { width: parent.dot; height: parent.dot; radius: width / 2; color: cFg }
            }
        }
    }

    // password keeps hyprlock's position (80 below centre), user sits above it
    Field {
        id: userField
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 80 * s - fieldH - fieldGap
        placeholder: "user"
        onSubmit: pwField.input.forceActiveFocus()
        onNext: pwField.input.forceActiveFocus()
    }
    Field {
        id: pwField
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 80 * s
        secret: true
        failed: root.state_ === "fail"
        placeholder: root.state_ === "fail" ? cfgS("wrongText", "Wrong password")
                   : root.state_ === "verify" ? cfgS("verifyText", "Verifying...")
                   : cfgS("text", "Locked")
        onSubmit: root.doLogin()
        onPrev: userField.input.forceActiveFocus()
    }

    // ── footer: session (left), power (right) ────────────────────────
    readonly property real footSize: clockSize / 6
    Text {
        anchors { left: parent.left; bottom: parent.bottom; margins: 24 * s }
        text: root.sessionName
        visible: text !== ""
        color: cFg; opacity: 0.6; font.family: fontName; font.pixelSize: footSize
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            onClicked: if (sessions.count > 1) root.sessionIdx = (root.sessionIdx + 1) % sessions.count }
    }
    Row {
        anchors { right: parent.right; bottom: parent.bottom; margins: 24 * s }
        spacing: 24 * s
        Text {
            text: "reboot"; visible: sddm.canReboot
            color: cFg; opacity: 0.6; font.family: fontName; font.pixelSize: footSize
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sddm.reboot() }
        }
        Text {
            text: "poweroff"; visible: sddm.canPowerOff
            color: cFg; opacity: 0.6; font.family: fontName; font.pixelSize: footSize
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sddm.powerOff() }
        }
    }

    Component.onCompleted: {
        userField.input.text = userModel.lastUser !== "" ? userModel.lastUser : userAt(userIdx)
        if (userField.input.text !== "") pwField.input.forceActiveFocus()
        else userField.input.forceActiveFocus()
    }
}
