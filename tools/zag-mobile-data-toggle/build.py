import plistlib, sys, uuid
P = "zag-mobile-data-toggle:v1"
INPUT = {"Value": {"Type": "ExtensionInput"}, "WFSerializationType": "WFTextTokenAttachment"}
actions = []
def act(ident, **params): actions.append({"WFWorkflowActionIdentifier": ident, "WFWorkflowActionParameters": params})
def say(text):
    u = str(uuid.uuid4()).upper()
    act("is.workflow.actions.gettext", UUID=u, WFTextActionText=text)
    act("is.workflow.actions.output", WFNoOutputSurfaceBehavior="Do Nothing",
        WFOutput={"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": {"Type": "ActionOutput", "OutputUUID": u, "OutputName": "Text"}}},
                  "WFSerializationType": "WFTextTokenString"})
def when(command, body):
    g = str(uuid.uuid4()).upper()
    act("is.workflow.actions.conditional", GroupingIdentifier=g, WFControlFlowMode=0, WFCondition=4,
        WFConditionalActionString=command, WFInput={"Type": "Variable", "Variable": INPUT})
    body()
    act("is.workflow.actions.conditional", GroupingIdentifier=g, WFControlFlowMode=2)
act("is.workflow.actions.comment", WFCommentActionText=
    "Zag Mobile Data Toggle (protocol v1) for Zag Store.\nInput: status, off or on. status changes nothing; anything else is refused without changes.\nhttps://zagstore.app/mobile-data-fix/")
when("status", lambda: say(f"{P}:ready"))
when("off", lambda: (act("is.workflow.actions.cellulardata.set", OnValue=False), say(f"{P}:off:done")))
when("on", lambda: (act("is.workflow.actions.cellulardata.set", OnValue=True), say(f"{P}:on:done")))
say(f"{P}:error:unknown-command")
wf = {
    "WFWorkflowActions": actions,
    "WFWorkflowClientVersion": "4711.1.3",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowHasOutputFallback": False,
    "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511},
    "WFWorkflowImportQuestions": [],
    "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
    "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
    "WFWorkflowTypes": [],
    "WFQuickActionSurfaces": [],
}
plistlib.dump(wf, open(sys.argv[1], "wb"), fmt=plistlib.FMT_BINARY)
