import QtQuick
import QtTest
import "../../shell/services" as Services

TestCase {
 name: "BarStatusSnapshot"
 Services.BarContent { id: content }
 function test_advertised_profile_choices_reach_public_snapshot() {
  content.powerProfile = {profile:"balanced", profiles:["power-saver","balanced"], profileServiceAvailable:true, onBattery:false, degradationReason:"none", capability:{available:true,ready:true,canChange:true}};
  const status=content.statusSnapshot().data.powerProfile;
  compare(status.profiles,["power-saver","balanced"]);
  verify(status.profileServiceAvailable);
  content.powerProfile = {profile:"unavailable", profiles:[], profileServiceAvailable:false, capability:{available:true,ready:true,canChange:false}};
  compare(content.statusSnapshot().data.powerProfile.profiles,[]);
 }
}
