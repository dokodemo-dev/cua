import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerTool(
    defineTool({
      name: "phase1_probe",
      label: "Phase 1 probe",
      description: "Write the isolated Phase 1 extension-executed marker.",
      parameters: Type.Object({}),
      async execute(_id, _params, _signal, _update, ctx) {
        await writeFile(join(ctx.cwd, "phase1-extension-executed"), "PHASE1_EXTENSION_EXECUTED\n");
        return {
          content: [{ type: "text", text: "PHASE1_EXTENSION_EXECUTED" }],
          details: { executed: true },
        };
      },
    }),
  );
}
