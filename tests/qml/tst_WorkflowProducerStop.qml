import "../../widgets/qml/Blox/Widgets/Providers" as Providers
import QtQuick
import QtTest

TestCase {
    id: test
    name: "WorkflowProducerStop"
    property var provider: null
    Component { id: factory; Providers.NativeProvider { enabled: true; brokerCommand: ["synthetic-broker"] } }
    SignalSpy { id: stopped; signalName: "consumerStopped" }
    function adapter(item) {
        if (typeof item.readChunk === "function") return item;
        if (item.item) { const found=adapter(item.item); if (found) return found; }
        const children=item.children || [];
        for (let i=0;i<children.length;i++) { const found=adapter(children[i]); if (found) return found; }
        return null;
    }
    function init() { provider=factory.createObject(test); stopped.target=provider; stopped.clear(); }
    function cleanup() { stopped.target=null; provider.destroy(); wait(0); }
    function prepare() {
        provider.subscribe("owned","command",{},7);
        wait(0);
        const broker=adapter(provider);
        verify(broker !== null);
        verify(broker.transportStarted);
        return broker;
    }
    function test_acknowledgement_is_required_and_forwarded_once() {
        const broker=prepare();
        verify(provider.unsubscribeAndWait("owned",7));
        compare(stopped.count,0);
        compare(Object.keys(provider.consumers).length,0);
        compare(Object.keys(broker.subscriptions).length,0);
        const pending=Object.keys(broker.stopRequests);
        compare(pending.length,1);
        broker.readChunk(JSON.stringify({requestId:Number(pending[0]),ok:true})+"\n");
        compare(stopped.count,1);
        compare(Array.from(stopped.signalArguments[0]),["owned",7,true]);
        broker.readChunk(JSON.stringify({requestId:Number(pending[0]),ok:true})+"\n");
        compare(stopped.count,1);
    }
    function test_lost_transport_fails_pending_teardown_without_replay() {
        const broker=prepare();
        verify(provider.unsubscribeAndWait("owned",7));
        const request=Number(Object.keys(broker.stopRequests)[0]);
        broker.connectionError("Synthetic disconnect");
        compare(stopped.count,1);
        compare(Array.from(stopped.signalArguments[0]),["owned",7,false]);
        compare(Object.keys(broker.stopRequests).length,0);
        broker.readChunk(JSON.stringify({requestId:request,ok:true})+"\n");
        compare(stopped.count,1);
        compare(Object.keys(broker.subscriptions).length,0);
    }
    function test_unavailable_teardown_drops_local_demand_and_does_not_start() {
        const broker=prepare();
        broker.transportStarted=false;
        verify(!provider.unsubscribeAndWait("owned",7));
        compare(stopped.count,0);
        compare(Object.keys(provider.consumers).length,0);
        compare(Object.keys(broker.subscriptions).length,0);
        compare(Object.keys(broker.stopRequests).length,0);
    }
}
