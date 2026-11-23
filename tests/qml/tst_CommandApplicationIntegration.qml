import "../../shell/services" as Services
import QtQuick
import QtTest
import Blox.Widgets 1.0

TestCase {
    id: test
    name: "CommandApplicationIntegration"
    when: windowShown
    visible: true
    width: 800
    height: 600
    property var host: null
    property var process: null
    property var desktop: null
    property var delegateLaunch: null
    property var delegateRelease: null
    property var shellLaunch: null
    property var shellValidation: null
    property string originBinding: ""
    property var subscriptions: ({})
    property int producerStarts: 0
    property bool delayStop: false
    property var pendingStop: null
    property var stopHook: null
    QtObject {
        id: provider
        property var actions: []
        signal snapshotReady(string consumerId, var envelope)
        signal consumerStopped(string consumerId, int generation, bool ok)
        signal connectionError(string message)
        signal reconnected()
        function subscribe(id, kind, settings, generation) { test.subscriptions[id] = generation; test.producerStarts++; }
        function unsubscribe(id) { delete test.subscriptions[id]; }
        function unsubscribeAndWait(id, generation) {
            delete test.subscriptions[id];
            if (test.stopHook) test.stopHook();
            if (test.delayStop) test.pendingStop={id:id,generation:generation};
            else consumerStopped(id,generation,true);
            return true;
        }
        function dispatchAction(id, action, payload, generation, hostContext) {
            actions = actions.concat([{id:id,action:action,payload:payload,generation:generation,hostContext:hostContext}]);
        }
    }
    Services.WidgetActionController {
        id: controller
        widgetItems: host ? [host.widget] : []
        workspaceId: 99
    }
    Component { id: component; WidgetHost { property string outputName: "DP-2" } }
    function source(path) {
        const request = new XMLHttpRequest(); request.open("GET",Qt.resolvedUrl(path),false); request.send();
        verify(request.status===0 || request.status===200); return request.responseText;
    }
    function block(text, marker) {
        const start=text.indexOf(marker); verify(start>=0,"Missing "+marker);
        let index=text.indexOf("{",start), depth=1;
        while (depth && ++index<text.length) { if (text[index]==="{") depth++; if (text[index]==="}") depth--; }
        return text.slice(start,index+1);
    }
    function initTestCase() {
        const desktopSource=source("../../shell/modules/DesktopWidgets.qml");
        const functions=["validateCommandHost","dispatchApplicationAction","beginCommandWorkflow","finishCommandWorkflow","releaseHostKeyboardFocus","releaseKeyboardFocus"]
            .map(name=>block(desktopSource,"function "+name+"(")).join("\n");
        desktop=Qt.createQmlObject('import QtQuick; QtObject { id:root; property var hosts:[]; property bool editMode:false; '
            +'property var keyboardHost:null; property string keyboardWidgetId:""; property string keyboardReturnAddress:""; '
            +'property int keyboardReturnPid:0; property string keyboardReturnClass:""; property int restores:0; '
            +'function restoreKeyboardReturnTarget(){restores++;} '
            +'signal applicationActionRequested(string action,var identity,var context); '+functions+'}',test);
        const launch=desktopSource.match(/onApplicationActionRequested:\s*\(action, identity, context\)\s*=>\s*([^\n]+)/);
        const release=desktopSource.match(/onFocusReleaseRequested:\s*([^\n]+)/);
        const origin=desktopSource.match(/trustedLaunchContext:\s*(\(\{outputName:[\s\S]*?\}\}\))/);
        verify(launch!==null && release!==null && origin!==null);
        delegateLaunch=new Function("host","root","action","identity","context","return "+launch[1]);
        delegateRelease=new Function("host","root","return "+release[1]);
        originBinding=origin[1];
        const shellSource=source("../../shell/shell.qml");
        const shell=shellSource.match(/onApplicationActionRequested:\s*\(action, identity, context\)\s*=>\s*([^\n]+)/);
        const validation=shellSource.match(/validateCommandHost:\s*([^\n]+)/);
        verify(shell!==null && validation!==null);
        shellLaunch=new Function("widgetActions","action","identity","context","return "+shell[1]);
        shellValidation=new Function("desktopWidgets","return ("+validation[1]+")")(desktop);
        desktop.applicationActionRequested.connect(function(action,identity,context){shellLaunch(controller,action,identity,context);});
    }
    function context() { return {outputName:"DP-2",workspace:{id:4,name:"4",special:false}}; }
    function profile() {
        return {id:"command", kind:"command", name:"Command", enabled:true,
            placement:{anchor:"top-left",x:0,y:0,width:300,height:200},
            workspaces:{mode:"all",ids:[],ranges:[]},visibility:"always",
            appearance:{backgroundOpacity:0.8,scrollbars:"auto",presentation:"open"},
            fullscreen:{enabled:false,mode:"native"}, settings:{
                command:["producer"],workingDirectory:"",environment:{},intervalSeconds:60,timeoutSeconds:15,
                fontFamily:"",fontSize:15,padding:24,
                actions:{left:{kind:"run",command:["finite"],workingDirectory:"",environment:{},timeoutSeconds:5},
                    right:{kind:"launch",command:["current-app","literal ; data"]}}}};
    }
    function init() {
        failOnWarning(/.*/);
        subscriptions=({}); producerStarts=0; delayStop=false; pendingStop=null; stopHook=null;
        provider.actions = [];
        if (process) process.sentSignals=[];
        host = component.createObject(test,{widget:profile(),provider:provider,
            workspace:{id:4,name:"4",special:false,empty:true},trustedLaunchContext:context()});
        desktop.hosts=[host]; desktop.editMode=false; desktop.keyboardHost=null; desktop.keyboardWidgetId=""; desktop.restores=0;
        controller.validateCommandHost=shellValidation;
        controller.beginCommandWorkflow=function(identity,context){return desktop.beginCommandWorkflow(identity,context);};
        controller.finishCommandWorkflow=function(identity){return desktop.finishCommandWorkflow(identity);};
        host.applicationWorkflowReady.connect(function(identity){controller.workflowReady(identity);});
        host.applicationWorkflowCancelled.connect(function(identity){controller.cancelWorkflow(identity);});
        host.applicationActionRequested.connect(function(action,identity,origin){delegateLaunch(host,desktop,action,identity,origin);});
        host.focusReleaseRequested.connect(function(){delegateRelease(host,desktop);});
        tryCompare(host,"phase","preparing");
        provider.snapshotReady(host.consumerId,{generation:host.revealGeneration,revision:1,observedMonotonicMs:0,
            state:"ready",value:{text:"Public fixture",error:"",exitCode:0},error:""});
        tryCompare(host,"phase","visible");
        process = findChild(controller,"widget-action-process");
    }
    function cleanup() {
        if (controller.activeRequest) controller.finish(1,0,'{}');
        process.running = false;
        desktop.hosts=[]; desktop.keyboardHost=null; desktop.keyboardWidgetId="";
        host.destroy(); host = null; wait(0);
    }
    function startWorkflow(topic, visibility) {
        const item=profile();
        item.visibility=visibility || "empty-workspace";
        item.settings.actions.right={kind:"run",command:["blox-widget-action",topic,topic === "todo" ? "edit" : "open"],
            workingDirectory:"",environment:{},timeoutSeconds:topic === "todo" ? 10 : 120};
        host.widget=item;
        tryCompare(host,"phase","preparing");
        provider.snapshotReady(host.consumerId,{generation:host.revealGeneration,revision:1,observedMonotonicMs:0,
            state:"ready",value:{text:"Public fixture"},error:""});
        tryCompare(host,"phase","visible");
        host.view.actionRequested("activate",{button:"right"});
        verify(controller.busy);
        verify(host._applicationWorkflow !== null);
        compare(provider.actions.length,0);
        verify(test.subscriptions[host.consumerId] === undefined);
        compare(process.command.slice(-2),["--workflow","4242"]);
        compare(JSON.parse(controller.activeRequest.input).hostContext,context());
    }
    function completeWorkflow() {
        process.stdout.text='{"ok":true,"code":"ok","message":""}';
        process.finish(0,0);
        process.stdout.streamFinished();
        verify(!controller.busy);
        compare(host._applicationWorkflow,null);
    }
    function test_synchronous_teardown_callback_data() {
        return [{tag:"config",change:"config"},{tag:"hide",change:"hide"},{tag:"expected-occupancy",change:"occupancy"}];
    }
    function test_synchronous_teardown_callback(row) {
        stopHook=function() {
            if (row.change === "hide") host.visible=false;
            if (row.change === "config") {const item=JSON.parse(JSON.stringify(host.widget));item.name="Changed";host.widget=item;}
            if (row.change === "occupancy") host.workspace={id:4,name:"4",special:false,empty:false};
        };
        startWorkflow("todo");
        compare(!!controller.activeRequest.inputSent,row.change === "occupancy");
        compare(!!controller.activeRequest.cancelled,row.change !== "occupancy");
        completeWorkflow();
    }
    function test_delayed_teardown_gates_input_and_stale_ack_cannot_start() {
        delayStop=true;
        startWorkflow("todo");
        verify(!controller.activeRequest.inputSent);
        verify(controller.activeRequest.waitingForProducer);
        provider.consumerStopped(pendingStop.id,pendingStop.generation-1,true);
        verify(!controller.activeRequest.inputSent);
        provider.consumerStopped(pendingStop.id,pendingStop.generation,true);
        verify(controller.activeRequest.inputSent);
        verify(!controller.activeRequest.waitingForProducer);
        completeWorkflow();
    }
    function test_cancel_while_waiting_blocks_late_teardown_ack() {
        delayStop=true;
        startWorkflow("todo");
        host.visible=false;
        verify(controller.activeRequest.cancelled);
        provider.consumerStopped(pendingStop.id,pendingStop.generation,true);
        verify(!controller.activeRequest.inputSent);
        completeWorkflow();
    }
    function test_teardown_failure_blocks_input() {
        delayStop=true;
        startWorkflow("todo");
        provider.consumerStopped(pendingStop.id,pendingStop.generation,false);
        verify(controller.activeRequest.cancelled);
        verify(!controller.activeRequest.inputSent);
        completeWorkflow();
    }
    function test_teardown_timeout_blocks_late_ack() {
        delayStop=true;
        startWorkflow("todo");
        findChild(controller,"widget-producer-stop-timeout").triggered();
        provider.consumerStopped(pendingStop.id,pendingStop.generation,true);
        verify(!controller.activeRequest.inputSent);
        completeWorkflow();
        compare(controller.lastResult.code,"timeout");
    }
    function test_todo_handoff_hide_keeps_only_finite_workflow() {
        startWorkflow("todo");
        const starts=producerStarts;
        const identity=controller.activeRequest.identity;
        host.workspace={id:4,name:"4",special:false,empty:false};
        tryCompare(host,"phase","hidden");
        verify(controller.busy); compare(process.sentSignals,[]);
        compare(controller.activeRequest.identity,identity);
        verify(test.subscriptions[host.consumerId] === undefined);
        completeWorkflow(); wait(0);
        compare(producerStarts,starts);
        host.workspace={id:4,name:"4",special:false,empty:true};
        tryCompare(host,"phase","preparing");
        compare(producerStarts,starts+1);
        compare(provider.actions.length,0);
    }
    function test_explicit_hide_after_expected_hide_still_cancels() {
        startWorkflow("todo");
        host.workspace={id:4,name:"4",special:false,empty:false};
        tryCompare(host,"phase","hidden");
        compare(process.sentSignals,[]);
        host.visible=false;
        verify(controller.activeRequest.cancelled);
        compare(process.sentSignals,[15]);
        completeWorkflow();
    }
    function test_calendar_focus_one_keeps_postlaunch_refresh() {
        startWorkflow("calendar");
        host.workspace={id:1,name:"1",special:false,empty:false};
        host.trustedLaunchContext={outputName:"DP-2",workspace:{id:1,name:"1",special:false}};
        tryCompare(host,"phase","hidden");
        compare(process.sentSignals,[]); verify(controller.busy);
        completeWorkflow(); wait(0);
        verify(test.subscriptions[host.consumerId] === undefined);
    }
    function test_workflow_cancellation_data() {
        return [{tag:"explicit-hide",change:"hide"},{tag:"unrelated-workspace",change:"workspace"},
            {tag:"config-change",change:"config"},{tag:"editing",change:"editing"},
            {tag:"explicit-refresh",change:"refresh"},{tag:"output-change",change:"output"}];
    }
    function test_workflow_cancellation(row) {
        startWorkflow("todo");
        if(row.change === "hide") host.visible=false;
        if(row.change === "workspace") host.workspace={id:8,name:"8",special:false,empty:false};
        if(row.change === "config") {const item=JSON.parse(JSON.stringify(host.widget)); item.name="Changed"; host.widget=item;}
        if(row.change === "editing") host.editing=true;
        if(row.change === "refresh") host.refresh();
        if(row.change === "output") host.trustedLaunchContext={outputName:"DP-3",workspace:context().workspace};
        verify(controller.activeRequest.cancelled);
        compare(process.sentSignals,[15]);
        verify(host._applicationWorkflow !== null);
        completeWorkflow();
        compare(controller.lastResult.code,"cancelled");
    }
    function test_reveal_during_workflow_has_no_new_producer_or_action_replay() {
        startWorkflow("todo");
        const starts=producerStarts;
        host.workspace={id:4,name:"4",special:false,empty:false}; wait(0);
        host.workspace={id:4,name:"4",special:false,empty:true}; wait(0);
        compare(producerStarts,starts);
        compare(provider.actions.length,0);
        const identity=controller.activeRequest.identity;
        compare(controller.dispatch("command","activate",identity,context()).code,"busy");
        completeWorkflow();
        tryCompare(host,"phase","preparing");
        compare(producerStarts,starts+1);
    }
    function test_run_captures_trusted_context_before_observation() {
        const observer = function() { host.trustedLaunchContext.outputName = "changed-by-observer"; };
        host.actionRequested.connect(observer);
        host.view.actionRequested("activate",{button:"left"});
        host.actionRequested.disconnect(observer);
        compare(provider.actions.length,1);
        compare(provider.actions[0].payload,{button:"left"});
        compare(provider.actions[0].hostContext,context());
        verify(!process.running);
        host.view.actionRequested("activate",{button:"left",hostContext:context()});
        compare(provider.actions.length,1);
    }
    function test_launch_only_application_owner_uses_origin_and_current_profile() {
        host.view.actionRequested("activate",{button:"right"});
        compare(provider.actions.length,0); verify(controller.busy);
        const input=JSON.parse(controller.activeRequest.input);
        compare(input.hostContext,context()); compare(input.hostContext.workspace.id,4);
        compare(input.widget.settings.actions.right.command,["current-app","literal ; data"]);
        compare(input.identity.consumerId,host.consumerId);
        compare(input.identity.generation,host.revealGeneration);
    }
    function test_fixed_host_callback_rejects_stale_generation_context_edit_and_hidden() {
        const identity={widgetId:"command",consumerId:host.consumerId,generation:host.revealGeneration,button:"right"};
        verify(host.isCurrentAction(identity,context()));
        const stale=Object.assign({},identity,{generation:identity.generation-1});
        compare(controller.dispatch("command","activate",stale,context()).code,"unavailable");
        const other=context(); other.outputName="DP-3";
        compare(controller.dispatch("command","activate",identity,other).code,"unavailable");
        host.editing=true;
        compare(controller.dispatch("command","activate",identity,context()).code,"unavailable");
        host.editing=false; host.visible=false;
        compare(controller.dispatch("command","activate",identity,context()).code,"unavailable");
        verify(!process.running); compare(provider.actions.length,0);
    }
    function test_callback_hide_cancels_before_either_owner() {
        const observer=function() {host.visible=false;};
        host.actionRequested.connect(observer);
        host.view.actionRequested("activate",{button:"right"});
        host.actionRequested.disconnect(observer);
        compare(provider.actions.length,0); verify(!process.running); verify(!controller.busy);
    }
    function test_production_origin_binding_uses_output_workspace_without_focus_lookup() {
        const subject=Qt.createQmlObject('import QtQuick; QtObject { property var host:({outputName:"DP-2"}); '
            +'property var outputSurface:({workspaceState:{id:4,name:"4",special:false,empty:true}}); '
            +'property var origin:'+originBinding+'}',test);
        compare(subject.origin,context());
        subject.outputSurface={workspaceState:{id:9,name:"9",special:false,empty:false}};
        compare(subject.origin.workspace,{id:9,name:"9",special:false});
        subject.destroy();
    }
    function test_production_focus_release_only_clears_exact_keyboard_host() {
        desktop.keyboardHost=host; desktop.keyboardWidgetId=host.widget.id;
        compare(delegateRelease({widget:{id:host.widget.id}},desktop),"stale");
        compare(desktop.keyboardHost,host); compare(desktop.restores,0);
        host.view.actionRequested("releaseFocus",{});
        compare(desktop.keyboardHost,null); compare(desktop.keyboardWidgetId,""); compare(desktop.restores,1);
    }
    function test_desktop_editing_and_removed_or_ambiguous_host_reject_launch() {
        const identity={widgetId:"command",consumerId:host.consumerId,generation:host.revealGeneration,button:"right"};
        desktop.editMode=true;
        compare(controller.dispatch("command","activate",identity,context()).code,"unavailable");
        desktop.editMode=false; desktop.hosts=[];
        compare(controller.dispatch("command","activate",identity,context()).code,"unavailable");
        desktop.hosts=[host,host];
        compare(controller.dispatch("command","activate",identity,context()).code,"unavailable");
        desktop.hosts=[host];
        verify(desktop.validateCommandHost(identity,context()));
        verify(!process.running);
    }
    function test_stale_origin_workspace_never_reaches_finite_provider() {
        host.trustedLaunchContext.workspace.id=9;
        host.view.actionRequested("activate",{button:"left"});
        compare(provider.actions.length,0); verify(!process.running); compare(host.phase,"visible");
    }
}
