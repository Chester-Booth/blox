import qs.shared
import QtQuick
import Quickshell.Services.Mpris

Column {
    id: root

    property string activePlayerName: ""
    property var mediaPlayers: []
    readonly property bool hasPlayers: root.players().length > 0

    signal selectPlayer(string playerName)

    function players() {
        return root.mediaPlayers || [];
    }

    function refreshPlayers() {
        root.mediaPlayers = Mpris.players && Mpris.players.values ? Mpris.players.values : [];
    }

    function effectivePlayerIndex() {
        const players = root.players();
        if (players.length === 0)
            return -1;

        for (let i = 0; i < players.length; i++) {
            if (players[i].dbusName === root.activePlayerName)
                return i;

        }
        for (let i = 0; i < players.length; i++) {
            if (players[i].isPlaying)
                return i;

        }
        return 0;
    }

    function activePlayer() {
        const index = root.effectivePlayerIndex();
        const players = root.players();
        return index >= 0 && index < players.length ? players[index] : null;
    }

    function selectRelativePlayer(delta) {
        const players = root.players();
        if (players.length < 2)
            return ;

        const next = (root.effectivePlayerIndex() + delta + players.length) % players.length;
        root.selectPlayer(players[next].dbusName);
    }

    function timeText(seconds) {
        if (!seconds || seconds < 0 || !isFinite(seconds))
            return "0:00";

        const total = Math.max(0, Math.floor(seconds));
        const minutes = Math.floor(total / 60);
        const rest = total % 60;
        return minutes + ":" + (rest < 10 ? "0" : "") + rest;
    }

    spacing: Theme.scaledSpacing(6)
    Component.onCompleted: refreshPlayers()

    Connections {
        function onValuesChanged() {
            root.refreshPlayers();
        }

        function onObjectInsertedPost() {
            root.refreshPlayers();
        }

        function onObjectRemovedPost() {
            root.refreshPlayers();
        }

        target: Mpris.players
    }

    Rectangle {
        id: media

        property var player: root.activePlayer()
        property int playerIndex: root.effectivePlayerIndex()
        property real visualPosition: player && player.positionSupported ? player.position : 0
        property real wheelAccumulatedX: 0
        property double wheelSwitchAllowedAt: 0
        readonly property bool hasPlayer: !!player
        readonly property real lengthValue: hasPlayer && player.lengthSupported ? Math.max(0, player.length) : 0
        readonly property real progress: lengthValue > 0 ? Math.max(0, Math.min(1, visualPosition / lengthValue)) : 0

        width: parent.width
        height: 108
        radius: Theme.scaledRadius(8)
        color: Theme.surface
        border.color: Theme.surfaceAlt
        border.width: 1
        clip: true
        onPlayerChanged: visualPosition = player && player.positionSupported ? player.position : 0
        onPlayerIndexChanged: switchAnimation.restart()

        SequentialAnimation {
            id: switchAnimation

            PropertyAction {
                target: mediaBody
                property: "opacity"
                value: 0.28
            }

            PropertyAction {
                target: mediaBody
                property: "scale"
                value: 0.985
            }

            ParallelAnimation {
                NumberAnimation {
                    target: mediaBody
                    property: "opacity"
                    to: 1
                    duration: 150
                    easing.type: Easing.OutCubic
                }

                NumberAnimation {
                    target: mediaBody
                    property: "scale"
                    to: 1
                    duration: 170
                    easing.type: Easing.OutCubic
                }

            }

        }

        Timer {
            interval: 1000
            running: media.hasPlayer && media.player.isPlaying && media.lengthValue > 0
            repeat: true
            onTriggered: media.visualPosition = Math.min(media.lengthValue, media.visualPosition + 1)
        }

        Connections {
            function onPositionChanged() {
                media.visualPosition = media.player.position;
            }

            function onTrackChanged() {
                media.visualPosition = media.player.positionSupported ? media.player.position : 0;
            }

            target: media.player
        }

        MouseArea {
            anchors.fill: parent
            z: 20
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
            onWheel: (wheel) => {
                const pixelX = wheel.pixelDelta.x || 0;
                const pixelY = wheel.pixelDelta.y || 0;
                const angleX = wheel.angleDelta.x || 0;
                const angleY = wheel.angleDelta.y || 0;
                const horizontal = Math.abs(pixelX) >= Math.abs(pixelY) && pixelX !== 0 ? pixelX * 8 : Math.abs(angleX) >= Math.abs(angleY) ? angleX : 0;
                const now = Date.now();
                if (horizontal === 0)
                    return ;

                wheel.accepted = true;
                media.wheelAccumulatedX += horizontal;
                if (Math.abs(media.wheelAccumulatedX) < 80 || now < media.wheelSwitchAllowedAt)
                    return ;

                root.selectRelativePlayer(media.wheelAccumulatedX > 0 ? -1 : 1);
                media.wheelAccumulatedX = 0;
                media.wheelSwitchAllowedAt = now + 260;
            }
        }

        Row {
            id: mediaBody

            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(8)
            spacing: Theme.scaledSpacing(10)
            visible: root.hasPlayers
            transformOrigin: Item.Center

            Rectangle {
                width: height
                height: parent.height
                radius: Theme.scaledRadius(6)
                color: Theme.background
                border.color: Qt.rgba(1, 1, 1, 0.1)
                border.width: 1
                clip: true

                Image {
                    id: albumImage

                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(1)
                    source: media.player && media.player.trackArtUrl ? media.player.trackArtUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    visible: status === Image.Ready
                }

                Text {
                    anchors.centerIn: parent
                    visible: !albumImage.visible
                    text: "󰎆"
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: 24
                }

            }

            Column {
                width: parent.width - parent.spacing - parent.children[0].width
                spacing: Theme.scaledSpacing(5)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    width: parent.width
                    text: media.player && media.player.trackTitle ? media.player.trackTitle : media.player ? media.player.identity : ""
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 14
                    font.bold: true
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: media.player && media.player.trackArtist ? media.player.trackArtist : media.player && media.player.trackAlbum ? media.player.trackAlbum : ""
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                Item {
                    width: parent.width
                    height: 14

                    Text {
                        anchors.left: parent.left
                        text: root.timeText(media.visualPosition)
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 10
                    }

                    Text {
                        anchors.right: parent.right
                        text: root.timeText(media.lengthValue)
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 10
                        horizontalAlignment: Text.AlignRight
                    }

                }

                Rectangle {
                    width: parent.width
                    height: 10
                    radius: 999
                    color: Theme.background
                    border.color: Qt.rgba(1, 1, 1, 0.08)
                    border.width: 1

                    Rectangle {
                        width: Math.max(parent.height, Math.round((parent.width - 2) * media.progress))
                        height: parent.height - 2
                        x: 1
                        y: 1
                        radius: 999
                        color: Theme.blue
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: media.player && media.player.canSeek && media.lengthValue > 0
                        hoverEnabled: true
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: (mouse) => {
                            const ratio = Math.max(0, Math.min(1, mouse.x / width));
                            media.player.position = ratio * media.lengthValue;
                            media.visualPosition = media.player.position;
                        }
                    }

                }

            }

        }

        Text {
            anchors.centerIn: parent
            visible: !root.hasPlayers
            text: "No media playing"
            color: Theme.muted
            font.family: Theme.bodyFontFamily
            font.pixelSize: 12
        }

    }

    Row {
        width: parent.width
        height: visible ? 10 : 0
        visible: root.players().length > 1
        spacing: Theme.scaledSpacing(6)

        Item {
            width: Math.max(0, (parent.width - dots.count * 6 - Math.max(0, dots.count - 1) * parent.spacing) / 2)
            height: 1
        }

        Repeater {
            id: dots

            model: root.players().length

            Rectangle {
                width: 6
                height: 6
                radius: 999
                anchors.verticalCenter: parent.verticalCenter
                color: index === root.effectivePlayerIndex() ? Theme.blue : Theme.surfaceAlt

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectPlayer(modelData.dbusName)
                }

            }

        }

    }

}
