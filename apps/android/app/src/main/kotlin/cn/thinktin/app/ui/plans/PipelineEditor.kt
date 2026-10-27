package cn.thinktin.app.ui.plans

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.data.model.Instance
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader

const val PIPELINE_STEP_TEST_TAG = "pipeline-step-"

/**
 * 流水线步骤的编辑（13.7，第 4.7 节）：每步一张卡片——键名、在哪个实例上跑、提示词、依赖哪些步骤（勾选），上下挪、删除；
 * 最多 20 步。不加步骤就是普通计划。问题（键名、依赖、环）在点保存后标出来。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PipelineStepsEditor(state: PlanEditUiState, viewModel: PlanEditViewModel) {
    SectionHeader(
        title = stringResource(R.string.plan_section_steps),
        actionLabel = stringResource(R.string.step_add).takeIf { state.canAddStep && state.steps.isNotEmpty() },
        onAction = viewModel::addStep,
    )
    Text(
        stringResource(if (state.steps.isEmpty()) R.string.pipeline_intro_empty else R.string.pipeline_intro),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    val problems = if (state.showStepProblems) state.stepProblems else emptyList()
    if (StepProblem.Cycle in problems) ProblemText(stringResource(R.string.step_problem_cycle))
    if (StepProblem.TooMany in problems) ProblemText(stringResource(R.string.step_problem_too_many, MAX_PIPELINE_STEPS))
    state.steps.forEachIndexed { index, step ->
        StepCard(
            step = step,
            index = index,
            count = state.steps.size,
            otherKeys = state.steps.filter { it.id != step.id }.map { it.key }.filter { it.isNotBlank() },
            instances = state.instances,
            problems = problems.filter { it.stepId == step.id },
            viewModel = viewModel,
        )
    }
    if (state.steps.isEmpty()) {
        SecondaryButton(text = stringResource(R.string.step_add_first), onClick = viewModel::addStep)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StepCard(
    step: StepDraft,
    index: Int,
    count: Int,
    otherKeys: List<String>,
    instances: List<Instance>,
    problems: List<StepProblem>,
    viewModel: PlanEditViewModel,
) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(PIPELINE_STEP_TEST_TAG + step.id),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val keyError = problems.firstOrNull { it is StepProblem.BadKey || it is StepProblem.DuplicateKey }
                OutlinedTextField(
                    value = step.key,
                    onValueChange = { viewModel.setStepKey(step.id, it) },
                    label = { Text(stringResource(R.string.step_key, index + 1)) },
                    singleLine = true,
                    isError = keyError != null,
                    supportingText = keyError?.let { e ->
                        {
                            Text(
                                stringResource(
                                    if (e is StepProblem.DuplicateKey) R.string.step_problem_duplicate_key else R.string.step_problem_bad_key,
                                ),
                            )
                        }
                    },
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { viewModel.moveStep(step.id, -1) }, enabled = index > 0) {
                    Icon(Icons.Outlined.ArrowUpward, contentDescription = stringResource(R.string.step_move_up, step.key))
                }
                IconButton(onClick = { viewModel.moveStep(step.id, 1) }, enabled = index < count - 1) {
                    Icon(Icons.Outlined.ArrowDownward, contentDescription = stringResource(R.string.step_move_down, step.key))
                }
                IconButton(onClick = { viewModel.removeStep(step.id) }) {
                    Icon(Icons.Outlined.Delete, contentDescription = stringResource(R.string.step_remove, step.key))
                }
            }
            Text(stringResource(R.string.step_instance), style = MaterialTheme.typography.labelMedium)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                instances.forEach { instance ->
                    FilterChip(
                        selected = step.instanceId == instance.id,
                        onClick = { viewModel.setStepInstance(step.id, instance.id) },
                        label = { Text(instance.name) },
                    )
                }
            }
            if (problems.any { it is StepProblem.NoInstance }) ProblemText(stringResource(R.string.step_problem_no_instance))
            if (problems.any { it is StepProblem.DeletedInstance }) ProblemText(stringResource(R.string.step_problem_deleted_instance))
            val promptError = problems.firstOrNull { it is StepProblem.EmptyPrompt || it is StepProblem.PromptTooLong }
            OutlinedTextField(
                value = step.prompt,
                onValueChange = { viewModel.setStepPrompt(step.id, it) },
                label = { Text(stringResource(R.string.step_prompt)) },
                minLines = 2,
                isError = promptError != null,
                supportingText = promptError?.let { e ->
                    {
                        Text(
                            if (e is StepProblem.PromptTooLong) {
                                stringResource(R.string.step_problem_prompt_too_long, MAX_STEP_PROMPT)
                            } else {
                                stringResource(R.string.step_problem_empty_prompt)
                            },
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
            if (otherKeys.isNotEmpty()) {
                Text(stringResource(R.string.step_depends_on), style = MaterialTheme.typography.labelMedium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    otherKeys.forEach { key ->
                        FilterChip(
                            selected = key in step.dependsOn,
                            onClick = { viewModel.toggleDependency(step.id, key) },
                            label = { Text(key) },
                        )
                    }
                }
            }
            problems.filterIsInstance<StepProblem.UnknownDependency>().forEach {
                ProblemText(stringResource(R.string.step_problem_unknown_dependency, it.key))
            }
            if (problems.any { it is StepProblem.SelfDependency }) ProblemText(stringResource(R.string.step_problem_self_dependency))
        }
    }
}

@Composable
private fun ProblemText(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
}
