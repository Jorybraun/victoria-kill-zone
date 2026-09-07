import {it} from "vitest";
import {createNodeRuntime} from "./node-runtime.js";
import {loadScenarios, runLoadScenario} from "./load-scenario.js";

declare const __VKZ_LOAD_MS__: number;

for (const scenario of loadScenarios) it(`independent Node client ${scenario}: native clock and durable event convergence`, async ({annotate, signal}) => {
  let session: Awaited<ReturnType<typeof createNodeRuntime>> | undefined;
  try {
    session = await createNodeRuntime(signal);
    await runLoadScenario(scenario, __VKZ_LOAD_MS__, session.runtime, annotate, signal);
  } finally {
    try {
      const diagnostics = session?.diagnostics();
      if (diagnostics) await annotate(JSON.stringify(diagnostics), "vkz-runtime-trace");
    } finally {await session?.close();}
  }
});
