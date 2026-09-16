// Documentation screenshots, not a test suite. Requires Node 22.13+, the
// ui-tests dependencies, and a freshly built UI served at WISP_TUTORIAL_URL.
// Uses the real frontend and a local mock bridge; never sends a model request.
import { readFileSync, mkdirSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const require = createRequire(resolve(root, 'ui-tests/package.json'));
const { chromium } = require('playwright');
const mock = stripTypeScriptTypes(readFileSync(resolve(root, 'ui-tests/tests/mock-tauri.ts'), 'utf8'))
  .replace(/^export /gm, '');
const init = `${mock}\ntauriMock();\n(${function () {
  const invoke = window.__TAURI__.core.invoke;
  window.__TAURI__.core.invoke = async (cmd, args) => {
    const result = await invoke(cmd, args);
    if (cmd !== 'list_workflow_templates') return result;
    // The shared fixture omits this built-in. Mirror its graph for the catalog
    // screenshots; instructions are shortened demonstration text.
    const tasks = [
      ['data_analysis', 'Assess observations, robustness and confounders.', [], 'code_run'],
      ['literature_landscape', 'Find verified consensus, contradictions and gaps.', [], 'literature_search'],
      ['research_design', 'Synthesize an eight-part research design with evidence markers.', ['data_analysis', 'literature_landscape'], 'reasoning'],
    ].map(([id, instruction, depends_on, capability]) => ({
      id, instruction, depends_on, capabilities: [capability], skill_ids: [],
      task_kind: 'agent', run_activity: null, specialist_id: null, output_schema: null,
      isolated: false, model_id: null, executor: null, budget: null,
    }));
    return [...result, {
      id: 'data_driven_research_design', name: 'Data-driven research design', builtin: true,
      description: 'Parallel data and literature assessment followed by an eight-part, source-marked research design.',
      proposal: { goal: 'Create a data-driven research design from project observations and literature',
        context: '', approval_policy: 'review_all', tasks },
    }];
  };
}.toString()})();`;
const browser = await chromium.launch({ headless: true });
try {
  for (const locale of ['zh', 'en']) {
    const context = await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 });
    const page = await context.newPage();
    page.on('pageerror', error => console.error(error.message));
    page.on('console', message => { if (message.type() === 'error') console.error(message.text()); });
    const tr = (zh, en) => locale === 'zh' ? zh : en;
    await page.addInitScript({ content: init });
    await page.goto(`${process.env.WISP_TUTORIAL_URL ?? 'http://127.0.0.1:1423'}/?mockLocale=${locale}`);
    await page.locator('.proj-card-main').first().click();
    const shot = async name => {
      await page.evaluate(async () => { await document.fonts.ready; });
      await page.mouse.move(0, 0);
      await page.waitForTimeout(400); // Let graph fit and modal transitions settle.
      const path = resolve(root, 'docs/assets/tutorials', locale === 'en' ? 'en' : '', 'agent-workflow', `${name}.png`);
      mkdirSync(dirname(path), { recursive: true });
      await page.screenshot({ path, animations: 'disabled' });
      console.log(path);
    };
    const composer = page.locator('#composer-input');
    await composer.pressSequentially('/round');
    await page.locator('.mention-menu .mention-item').filter({ hasText: 'Roundtable' }).click();
    await composer.fill(tr('请比较“先补功能实验”和“先分析独立数据”两种研究安排。预算有限，四周后汇报；请保留分歧并给出下一步建议。', 'Compare functional experiments with independent-data analysis as our next step. Budget is limited and the presentation is in four weeks. Preserve disagreements and recommend next steps.'));
    await shot('02-composer');
    await page.getByRole('button', { name: tr('设置', 'Settings'), exact: true }).click();
    await page.locator('.settings-nav').getByRole('button', { name: tr('工作流', 'Workflows'), exact: true }).click();
    for (const [name, file] of [
      ['Literature evidence review', '01-library'], ['Roundtable', '03-roundtable'],
      ['Data-driven research design', '04-research-design'], ['Develop computational method', '05-method-search'],
    ]) {
      await page.getByTestId('workflow-template-card').filter({ hasText: name }).click();
      await shot(file);
    }
    await page.getByTestId('workflow-new').click();
    await shot('06-new');
    await page.getByTestId('portfolio-planner-open').click();
    await page.getByTestId('portfolio-request').fill(tr('根据 literature-review 的方法，将观点核查拆成支持证据、挑战性证据和综合结论三个任务，保留来源与不确定性。', 'Convert literature-review into supporting-evidence, challenging-evidence and synthesis tasks. Preserve sources and uncertainty.'));
    await page.getByTestId('portfolio-source-manual').click();
    await page.locator('[data-testid="portfolio-source-skill"][value="literature-review"]').check();
    await shot('09-from-skill');
    await page.getByTestId('portfolio-background').click();
    await page.getByTestId('workflow-new').click();
    await page.getByTestId('workflow-new-scratch').click();
    await page.getByTestId('workflow-name').fill(tr('研究论证检查', 'Research argument review'));
    await page.getByTestId('workflow-description').fill(tr('独立梳理论点和核查证据，再汇总修改建议。', 'Extract claims and examine evidence independently, then propose revisions.'));
    await page.getByTestId('workflow-goal').fill(tr('根据本轮提供的段落和证据摘要，检查论证是否充分，输出有依据的修改建议。', 'Review the supplied passage and evidence summary; return evidence-grounded revisions.'));
    await page.getByTestId('workflow-approval-policy').selectOption('review_all');
    await page.locator('.dynamic-agent-context > summary').click();
    await page.getByTestId('workflow-context').fill(tr('只使用本轮材料；缺失信息标为“材料未提供”。不补写文献、数据或已完成的实验。不写入项目文件。', 'Use only supplied material. Mark missing information explicitly. Do not invent sources, data or completed experiments. Do not write project files.'));
    const instructions = [
      tr('读取本轮提供的研究段落。逐条列出主要判断，编号 C1、C2……，区分观察事实、相关性描述和因果推测。保留对应原文短句；不判断未提供的证据。', 'Extract and number claims C1, C2, etc. Distinguish observations, correlations and causal inference. Quote the relevant passage; do not infer missing evidence.'),
      tr('独立检查本轮段落与证据摘要。列出各项证据能够支持的范围、限制和替代解释，引用对应原文短句。缺少样本量、对照或统计信息时明确标注，不补造结果。', 'Independently review the passage and evidence summary. Identify support, limits and alternatives with source excerpts. Flag missing sample sizes, controls or statistics; invent nothing.'),
      tr('读取 claims 和 evidence_check 的依赖结果。逐条对应主张与证据，输出“原判断、证据支持程度、建议表述、待验证问题”四列表格。保留分歧，不新增来源，最后给出三项优先修改。', 'Read the claims and evidence_check dependency results. Return a table of original claim, evidence strength, suggested wording and open questions. Preserve disagreement and finish with three priority revisions.'),
    ];
    for (let i = 0; i < 3; i++) {
      if (i) {
        await page.getByTestId('workflow-graph-add-menu-toggle').click();
        await page.getByTestId('workflow-graph-add-node').click();
      }
      if (!i) await page.getByTestId('workflow-graph-node-select').first().dblclick();
      await page.getByTestId('dynamic-task-id').fill(['claims', 'evidence_check', 'synthesis'][i]);
      await page.getByTestId('dynamic-task-instruction').fill(instructions[i]);
      if (i === 2) {
        await page.locator('.dynamic-task-dependency-group > summary').click();
        for (const dependency of ['claims', 'evidence_check']) {
          await page.locator('.dynamic-dependency-checks label').filter({ hasText: dependency }).getByRole('checkbox').check();
        }
        await shot('07-node-editor');
      }
      await page.getByTestId('workflow-inspector-close').click();
    }
    await page.getByTestId('workflow-save').click();
    await page.getByTestId('workflow-template-card').filter({ hasText: tr('研究论证检查', 'Research argument review') }).waitFor();
    await shot('08-custom-graph');
    await context.close();
  }
} finally {
  await browser.close();
}
