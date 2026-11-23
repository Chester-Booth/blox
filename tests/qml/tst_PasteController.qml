import QtQuick
import QtTest
import Quickshell.Hyprland
import "../../shell/modules" as Modules
TestCase {
 name: "PickerFocusReturn"
 Component { id: controller; Modules.PasteController {} }
 function owner() {
  const result=createTemporaryObject(controller,this);
  result.targetAddress="abc"; result.targetPid=42; result.targetClass="editor";
  return result;
 }
 function cleanup() { Hyprland.activeToplevel = null; }
 function test_capture_keeps_original_target_while_picker_is_focused_and_clears_missing_target() {
  const result=owner();
  Hyprland.activeToplevel={lastIpcObject:{address:"0xdef",pid:99,class:"browser",title:"Page"}};
  result.captureTarget();
  compare(result.targetAddress,"def");
  compare(result.targetPid,99);
  result.tracking=true;
  Hyprland.activeToplevel={lastIpcObject:{address:"0xaaa",pid:7,class:"org.quickshell",title:"Blox Clipboard"}};
  result.captureTarget();
  compare(result.targetAddress,"def");
  compare(result.targetPid,99);
  compare(result.targetClass,"browser");
  result.tracking=false;
  Hyprland.activeToplevel=null;
  result.captureTarget();
  compare(result.targetAddress,"");
  compare(result.targetPid,0);
  compare(result.targetClass,"");
  verify(!result.restoreTarget());
 }
 function test_tracking_retains_target_until_a_complete_app_window_is_observed() {
  const result=owner();
  result.tracking=true;
  Hyprland.activeToplevel={lastIpcObject:{address:"0xdef",pid:99,class:"browser",title:"Page"}};
  result.captureTarget();
  compare(result.targetAddress,"def");
  compare(result.targetPid,99);
  compare(result.targetClass,"browser");

  const incompleteWindows=[
   null,
   {lastIpcObject:{}},
   {lastIpcObject:{address:"0xaaa",class:"browser",title:"Missing PID"}},
   {lastIpcObject:{address:"0xaaa",pid:7,title:"Missing class"}},
   {lastIpcObject:{pid:7,class:"browser",title:"Missing address"}}
  ];
  for (const window of incompleteWindows) {
   Hyprland.activeToplevel=window;
   result.captureTarget();
   compare(result.targetAddress,"def");
   compare(result.targetPid,99);
   compare(result.targetClass,"browser");
  }

  Hyprland.activeToplevel={lastIpcObject:{address:"0x123",pid:77,class:"editor",title:"Document"}};
  result.captureTarget();
  compare(result.targetAddress,"123");
  compare(result.targetPid,77);
  compare(result.targetClass,"editor");

  Hyprland.activeToplevel={lastIpcObject:{address:"0xaaa",pid:7,class:"org.quickshell",title:"Blox Clipboard"}};
  result.captureTarget();
  compare(result.targetAddress,"123");
  compare(result.targetPid,77);
  compare(result.targetClass,"editor");
  result.tracking=false;
 }
 function test_idle_capture_clears_stale_target_for_missing_window() {
  const result=owner();
  result.tracking=false;
  Hyprland.activeToplevel=null;
  result.captureTarget();
  compare(result.targetAddress,"");
  compare(result.targetPid,0);
  compare(result.targetClass,"");
  verify(!result.restoreTarget());
 }
 function test_idle_capture_clears_stale_target_when_picker_is_active() {
  const result=owner();
  result.tracking=false;
  Hyprland.activeToplevel={lastIpcObject:{address:"0xdef",pid:99,class:"org.quickshell",title:"Blox Clipboard"}};
  result.captureTarget();
  compare(result.targetAddress,"");
  compare(result.targetPid,0);
  compare(result.targetClass,"");
  verify(!result.restoreTarget());
 }
 function test_dismissal_restores_without_pasting() {
  const result=owner();
  verify(result.restoreTarget());
  const restore=findChild(result,"picker-focus-restore");
  verify(restore.running);
  verify(!result.pending);
  restore.finish(0,0);
  verify(!findChild(result,"picker-paste").running);
 }
 function test_paste_waits_for_restore_then_verifies_focus() {
  const result=owner();
  result.pasteWhenRestored();
  verify(result.pending);
  const active=findChild(result,"picker-active-window");
  verify(!active.running);
  findChild(result,"picker-focus-restore").finish(0,0);
  tryCompare(active,"running",true);
  active.stdout.text=JSON.stringify({address:"0xabc"});
  active.stdout.streamFinished();
  verify(findChild(result,"picker-paste").running);
  verify(!result.pending);
 }
 function test_wrong_focus_never_pastes_after_failed_restore() {
  const result=owner();
  result.pasteWhenRestored();
  findChild(result,"picker-focus-restore").finish(1,0);
  const active=findChild(result,"picker-active-window");
  tryCompare(active,"running",true);
  result.deadline=0;
  active.stdout.text=JSON.stringify({address:"0xdef"});
  active.stdout.streamFinished();
  verify(!findChild(result,"picker-paste").running);
  verify(!result.pending);
 }
}
