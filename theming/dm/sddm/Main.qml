import QtQuick
import QtQuick.Effects

// Mirrors hyprlock 0.9's input field: outline drawn outside the box, dots
// sized and spaced like its defaults, and its default animations (800 ms on
// the hyprutils "default" bezier, field colors 800 ms linear). hyprlock font
// sizes are points (pango at 96 dpi), hence pt().
Rectangle {
    id: root
    width: 1280
    height: 800
    color: "black"

    // ── config helpers (SDDM config values arrive as strings) ─────────
    function cfgS(k, d) { var v = config[k]; return (v === undefined || v === null || v === "") ? d : String(v) }
    function cfgN(k, d) { var v = parseFloat(cfgS(k, "")); return isNaN(v) ? d : v }
    function cfgB(k, d) { var v = cfgS(k, ""); return v === "" ? d : (v === "true" || v === "1") }

    // scale is in physical pixels; dividing by the window's pixel ratio keeps
    // sizes identical whether Qt runs unscaled (Weston) or scaled (preview
    // window under Hyprland)
    readonly property real s: cfgN("scale", 1.0) / Screen.devicePixelRatio
    function pt(p) { return p * 4 / 3 * s }

    readonly property bool preview: cfgB("preview", false)
    readonly property color cBg: cfgS("bg", "#000000")
    readonly property color cFg: cfgS("fg", "#dfdfdf")
    readonly property color cAccent: cfgS("accent", "#5EA4B8")
    readonly property color cWrong: cfgS("wrong", "#cc241d")
    readonly property string fontName: cfgS("font", "monospace")
    readonly property int clockSize: cfgN("clockSize", 104)
    readonly property real fieldW: cfgN("fieldWidth", 300) * s
    readonly property real fieldH: cfgN("fieldHeight", 55) * s
    readonly property real outline: cfgN("border", 2) * s
    readonly property real rounding: cfgN("rounding", 2) * s

    readonly property var easeDefault: [0.0, 0.75, 0.15, 1.0, 1.0, 1.0]
    readonly property int animMs: 800

    readonly property bool capsLock: typeof keyboard !== "undefined" && keyboard !== null && keyboard.capsLock

    // idle | verify | fail. fail clears after 2 s or on the next key, like
    // hyprlock's general:fail_timeout.
    property string state_: "idle"

    // ── users / sessions ─────────────────────────────────────────────
    property int userIdx: Math.max(0, userModel.lastIndex)
    property int sessionIdx: Math.max(0, sessionModel.lastIndex)
    Repeater { id: users; model: userModel; delegate: Item { required property string name } }
    function userAt(i) { return users.count > 0 && users.itemAt(i) ? users.itemAt(i).name : "" }

    // hyprlock has no user field: it only appears when no user is known, or
    // on Up/Shift+Tab from the password field.
    property bool askUser: false

    function doLogin() {
        if (state_ === "verify") return
        if (userField.input.text === "") { askUser = true; userField.input.forceActiveFocus(); return }
        state_ = "verify"
        failTimer.stop()
        if (preview) previewTimer.start()
        else sddm.login(userField.input.text, pwField.input.text, sessionIdx)
    }
    function fail() {
        state_ = "fail"
        pwField.input.text = ""
        pwField.input.forceActiveFocus()
        failTimer.restart()
    }
    function clearFail() { if (state_ === "fail") { state_ = "idle"; failTimer.stop() } }

    Timer { id: previewTimer; interval: 900; onTriggered: root.fail() }
    Timer { id: failTimer; interval: 2000; onTriggered: root.clearFail() }
    Connections {
        target: sddm
        function onLoginFailed() { root.fail() }
        function onLoginSucceeded() { fadeOut.start() }
    }

    // hidden like hyprlock's hide_cursor until the mouse moves, so the
    // session and power pills stay clickable
    property bool cursorShown: false
    MouseArea {
        anchors.fill: parent
        z: 10
        enabled: !root.cursorShown
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        cursorShape: Qt.BlankCursor
        onPositionChanged: root.cursorShown = true
    }

    Item {
        id: content
        anchors.fill: parent

        NumberAnimation on opacity {
            from: 0; to: 1; duration: root.animMs
            easing.type: Easing.Bezier; easing.bezierCurve: root.easeDefault
        }
        NumberAnimation {
            id: fadeOut
            target: content; property: "opacity"; to: 0; duration: root.animMs
            easing.type: Easing.Bezier; easing.bezierCurve: root.easeDefault
        }

        // ── background: wallpaper, blurred + dimmed (hyprlock background{}) ──
        // layer caches the composite so key presses and the clock tick only
        // repaint the widgets above, not the blur.
        Item {
            anchors.fill: parent
            layer.enabled: true

            Rectangle { anchors.fill: parent; color: root.cBg }
            Image {
                id: wall
                anchors.fill: parent
                source: root.cfgS("background", "") === "" ? "" : "file://" + root.cfgS("background", "")
                fillMode: Image.PreserveAspectCrop
                visible: false
            }
            MultiEffect {
                anchors.fill: parent
                source: wall
                visible: wall.status === Image.Ready
                blurEnabled: root.cfgB("blur", true)
                blur: 0.6
                blurMax: 48
                saturation: root.cfgN("vibrancy", 0.2)
            }
            Rectangle {
                anchors.fill: parent
                color: "black"
                opacity: 1.0 - root.cfgN("dim", 0.5)
                visible: wall.status === Image.Ready
            }
        }

        // ── clock + date (hyprlock label{} x2, y is up-positive there) ────
        property date now: new Date()
        Timer { interval: 1000; running: true; repeat: true; onTriggered: content.now = new Date() }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -180 * root.s
            text: Qt.formatTime(content.now, "HH:mm:ss")
            color: root.cFg
            renderType: Text.NativeRendering
            font.family: root.fontName
            font.pixelSize: root.pt(root.clockSize)
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -100 * root.s
            text: Qt.formatDate(content.now, "dddd, MMMM dd, yyyy")
            color: root.cFg
            renderType: Text.NativeRendering
            font.family: root.fontName
            font.pixelSize: root.pt(Math.floor(root.clockSize / 3))
        }

        // ── input field (hyprlock input-field{}) ─────────────────────────
        // The item is the outline box; the field box sits `outline` inside it.
        component Field: Item {
            id: f
            property alias input: ti
            property bool secret: false
            property string placeholder: ""
            property bool failed: false
            property bool checking: false
            property real dots: 0
            signal submit()
            signal next()
            signal prev()

            readonly property color outerColor: root.capsLock && !checking && !(failed && ti.text.length === 0) ? root.cWrong
                                              : checking ? root.cAccent
                                              : failed && ti.text.length === 0 ? root.cWrong
                                              : root.cAccent
            readonly property color fontColor: failed ? root.cWrong : root.cFg

            // grows to fit a long placeholder, like hyprlock's inputFieldWidth
            readonly property real boxW: Math.max(root.fieldW,
                ti.text.length === 0 && ph.visible ? ph.implicitWidth + root.fieldH : 0)
            width: box.width + 2 * root.outline
            height: root.fieldH + 2 * root.outline
            anchors.horizontalCenter: parent.horizontalCenter

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: Math.min(root.rounding + root.outline, height / 2)
                border.width: root.outline
                border.color: f.outerColor
                Behavior on border.color { ColorAnimation { duration: root.animMs } }
            }

            Rectangle {
                id: box
                anchors.centerIn: parent
                width: f.boxW
                height: root.fieldH
                radius: Math.min(root.rounding, height / 2)
                color: root.cBg
                clip: true
                Behavior on width {
                    NumberAnimation { duration: root.animMs; easing.type: Easing.Bezier; easing.bezierCurve: root.easeDefault }
                }

                TextInput {
                    id: ti
                    anchors.fill: parent
                    anchors.leftMargin: root.fieldH / 2
                    anchors.rightMargin: root.fieldH / 2
                    horizontalAlignment: TextInput.AlignHCenter
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: f.fontColor
                    selectionColor: root.cAccent
                    renderType: Text.NativeRendering
                    font.family: root.fontName
                    // hyprlock: placeholder font_size = field height / 4
                    font.pixelSize: root.pt(Math.floor(root.fieldH / root.s / 4))
                    // secret fields draw their own dots below, like hyprlock
                    opacity: f.secret ? 0 : 1
                    cursorVisible: !f.secret && activeFocus
                    readOnly: root.state_ === "verify"
                    Keys.onReturnPressed: f.submit()
                    Keys.onEnterPressed: f.submit()
                    Keys.onTabPressed: f.next()
                    Keys.onDownPressed: f.next()
                    Keys.onBacktabPressed: f.prev()
                    Keys.onUpPressed: f.prev()
                    Keys.onEscapePressed: root.preview ? Qt.quit() : (text = "")
                    Keys.onPressed: root.clearFail()
                    onTextChanged: {
                        if (!f.secret) return
                        if (text.length === 0) { dotAnim.stop(); f.dots = 0 }
                        else { dotAnim.to = text.length; dotAnim.restart() }
                    }
                }

                NumberAnimation {
                    id: dotAnim
                    target: f; property: "dots"; duration: root.animMs
                    easing.type: Easing.Bezier; easing.bezierCurve: root.easeDefault
                }

                Text {
                    id: ph
                    anchors.centerIn: parent
                    visible: ti.text.length === 0 && root.state_ !== "verify"
                    text: f.placeholder
                    color: f.fontColor
                    renderType: Text.NativeRendering
                    font: ti.font
                }

                // hyprlock dots: size 0.25 of the field height (rounded to an
                // even pixel count), spacing 0.2 of a dot, centered; the newest
                // dot fades in while the row slides to stay centered.
                Item {
                    id: dotRow
                    anchors.fill: parent
                    visible: f.secret
                    readonly property real d: Math.round(root.fieldH / root.s * 0.25 * 0.5) * 2 * root.s
                    readonly property real sp: Math.floor(d / root.s * 0.2) * root.s
                    readonly property real pad: (box.height - d) / 2
                    readonly property real areaW: box.width - 2 * pad
                    readonly property int maxDots: Math.round(areaW / (d + sp))
                    readonly property int whole: Math.floor(f.dots)
                    readonly property real curW: (d + sp) * f.dots - sp
                    readonly property real xstart: f.dots > maxDots
                        ? (box.width + maxDots * (d + sp) - sp - 2 * curW) / 2
                        : (areaW - curW) / 2 + pad

                    Repeater {
                        model: f.secret ? Math.ceil(f.dots) : 0
                        Rectangle {
                            required property int index
                            visible: index >= dotRow.whole - dotRow.maxDots
                            x: dotRow.xstart + index * (dotRow.d + dotRow.sp)
                            y: dotRow.pad
                            width: dotRow.d; height: dotRow.d; radius: width / 2
                            color: f.fontColor
                            opacity: f.dots === dotRow.whole ? 1
                                   : index === dotRow.whole ? f.dots - dotRow.whole
                                   : index === dotRow.whole - dotRow.maxDots ? 1 - f.dots + dotRow.whole
                                   : 1
                        }
                    }
                }
            }
        }

        // password keeps hyprlock's position (80 below centre), user sits above it
        Field {
            id: userField
            visible: root.askUser
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 80 * root.s - height - 12 * root.s
            placeholder: "user"
            onSubmit: pwField.input.forceActiveFocus()
            onNext: pwField.input.forceActiveFocus()
        }
        Field {
            id: pwField
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 80 * root.s
            secret: true
            failed: root.state_ === "fail"
            checking: root.state_ === "verify"
            placeholder: root.state_ === "fail" ? root.cfgS("wrongText", "Wrong password") : root.cfgS("text", "Locked")
            onSubmit: root.doLogin()
            onPrev: { root.askUser = true; userField.input.forceActiveFocus() }
        }

        // ── footer: waybar island pills, sessions (left), power (right) ──
        readonly property real gap: root.cfgN("gaps", 10) * root.s
        readonly property real pillH: root.cfgN("pillHeight", 27) * root.s
        readonly property real pillR: root.cfgN("pillRadius", 8) * root.s
        readonly property color pillBg: Qt.rgba(root.cBg.r, root.cBg.g, root.cBg.b, root.cfgN("pillOpacity", 0.8))
        readonly property color hoverBg: Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.9)
        readonly property real shadowBlur: root.cfgN("pillShadow", 4) * root.s

        component PillText: Text {
            anchors.centerIn: parent
            renderType: Text.NativeRendering
            font.family: root.cfgS("pillFont", root.fontName)
            font.pixelSize: root.cfgN("pillFontSize", 12) * root.s
        }

        // hover fill: rounded only on the outer ends of a segmented pill
        component HoverFill: Item {
            property bool first: true
            property bool last: true
            property bool shown: false
            anchors.fill: parent
            opacity: shown ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 300 } }
            Rectangle { anchors.fill: parent; radius: content.pillR; color: content.hoverBg }
            Rectangle { visible: !parent.first; width: parent.width / 2; height: parent.height; color: content.hoverBg }
            Rectangle { visible: !parent.last; x: parent.width / 2; width: parent.width / 2; height: parent.height; color: content.hoverBg }
        }

        component PillShadow: MultiEffect {
            shadowEnabled: content.shadowBlur > 0
            shadowColor: Qt.rgba(0, 0, 0, root.cfgN("pillShadowAlpha", 0.5))
            shadowHorizontalOffset: 0
            shadowVerticalOffset: root.s
            shadowBlur: 1.0
            blurMax: Math.max(1, Math.round(content.shadowBlur))
        }

        // sessions, like waybar's workspaces: one segmented pill, the
        // selected session in accent
        Rectangle {
            anchors { left: parent.left; bottom: parent.bottom; margins: content.gap }
            visible: sessionRep.count > 0
            width: sessionRow.width
            height: content.pillH
            radius: content.pillR
            color: content.pillBg
            layer.enabled: content.shadowBlur > 0
            layer.effect: PillShadow {}

            Row {
                id: sessionRow
                height: parent.height
                Repeater {
                    id: sessionRep
                    model: sessionModel
                    Item {
                        id: seg
                        required property int index
                        required property string name
                        width: label.implicitWidth + 24 * root.s
                        height: parent.height
                        HoverFill { first: seg.index === 0; last: seg.index === sessionRep.count - 1; shown: segMouse.containsMouse }
                        PillText {
                            id: label
                            text: seg.name
                            color: segMouse.containsMouse ? root.cBg
                                 : seg.index === root.sessionIdx ? root.cAccent : root.cFg
                        }
                        Rectangle {
                            visible: seg.index < sessionRep.count - 1
                            anchors.right: parent.right
                            width: root.s; height: parent.height
                            color: Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.2)
                        }
                        MouseArea {
                            id: segMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.sessionIdx = seg.index
                        }
                    }
                }
            }
        }

        Row {
            anchors { right: parent.right; bottom: parent.bottom; margins: content.gap }
            spacing: 4 * root.s
            Repeater {
                model: [
                    { label: "reboot", ok: sddm.canReboot, act: function() { sddm.reboot() } },
                    { label: "poweroff", ok: sddm.canPowerOff, act: function() { sddm.powerOff() } }
                ]
                Rectangle {
                    id: pw
                    required property var modelData
                    visible: modelData.ok
                    width: pwLabel.implicitWidth + 20 * root.s
                    height: content.pillH
                    radius: content.pillR
                    color: content.pillBg
                    layer.enabled: content.shadowBlur > 0
                    layer.effect: PillShadow {}
                    HoverFill { shown: pwMouse.containsMouse }
                    PillText { id: pwLabel; text: pw.modelData.label; color: pwMouse.containsMouse ? root.cBg : root.cFg }
                    MouseArea {
                        id: pwMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (!root.preview) pw.modelData.act()
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        userField.input.text = userModel.lastUser !== "" ? userModel.lastUser : userAt(userIdx)
        if (userField.input.text !== "") pwField.input.forceActiveFocus()
        else { askUser = true; userField.input.forceActiveFocus() }
    }
}
