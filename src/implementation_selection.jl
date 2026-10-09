"""Resource selection among supplied numerical certificates, retaining rejected candidates."""
struct ImplementationSelection
    candidates::Tuple{Vararg{CertificationResult}}
    selected_index::Union{Nothing, Int}
    selected::Union{Nothing, CertificationResult}
    status::Symbol
    reason::String
    rows::Tuple{Vararg{PolynomialSweepRow}}
    pareto_indices::Tuple{Vararg{Int}}
    memory_model::BlockMemoryModel
    max_table_blocks::Union{Nothing, BigInt}
    resource_model::Union{Nothing, ResourceModel}
    resource_budget::ResourceBudget
    objective::Symbol
end

"""
    select_implementation(certificates; resource_model=nothing, resource_budget=ResourceBudget(),
        objective=:resources, memory_model=..., max_table_blocks=nothing,
        implementation=:auto)

Select among certified LUT/polynomial evaluators of the same exact contract.
Uses the same priorities, limits, unknown-cost handling and Pareto metrics as
`sweep_implementations`. Explicit overrides filter candidates, preserving both
numerical and resource requirements. Without a profile use modeled memory cost.
Input certificates are process-local proof results, as in sweep selection.
"""
function select_implementation(
    certificates::Union{Tuple, AbstractVector};
    resource_model::Union{Nothing, ResourceModel} = nothing,
    resource_budget::ResourceBudget = ResourceBudget(),
    objective::Symbol = resource_model === nothing ? :memory : :resources,
    memory_model::BlockMemoryModel = resource_model === nothing ? BlockMemoryModel() :
                                     resource_model.memory,
    max_table_blocks = nothing,
    implementation::Symbol = :auto,
)
    !isempty(certificates) && all(c -> c isa CertificationResult, certificates) ||
        throw(ArgumentError("supply a nonempty list of numerical certificates"))
    implementation in (:auto, :lut, :polynomial) ||
        throw(ArgumentError("implementation must be auto, lut or polynomial"))
    spec = first(certificates).plan.spec
    all(c -> _spec_data(c.plan.spec) == _spec_data(spec), certificates) ||
        throw(ArgumentError("implementation candidates must share the same exact contract"))
    budget = _validate_sweep_selection(
        max_table_blocks,
        objective,
        resource_model,
        resource_budget,
    )
    rows = Tuple(
        map(enumerate(certificates)) do (i, c)
            kind =
                get(c.plan.settings, "kernel", "") == "full_lut" ||
                get(c.settings, "method", "") == "exhaustive_lut" ? :lut : :polynomial
            eligible = implementation == :auto || kind == implementation
            valid =
                c.status != :certified || (
                    c.plan.program !== nothing &&
                    c.total_bound !== nothing &&
                    0 <= c.total_bound <= spec.absolute_error
                )
            valid || throw(
                ArgumentError(
                    "a certified candidate must have a program and a bound meeting its contract",
                ),
            )
            attempt = SearchAttempt(
                0,
                spec.output_format,
                max(1, length(c.plan.segments)),
                c.plan.precision,
                eligible ? c.status : :implementation_excluded,
                0.0,
                c.plan,
                c,
                eligible ? c.reason : "Excluded by $implementation override",
            )
            PolynomialSweepRow(i, 1, attempt, :disabled, nothing, 0.0, kind)
        end,
    )
    pareto, selections = _sweep_choices(
        rows,
        1,
        memory_model,
        budget,
        objective,
        resource_model,
        resource_budget,
    )
    selection = only(selections)
    chosen = selection.row_index
    return ImplementationSelection(
        Tuple(certificates),
        chosen,
        chosen === nothing ? nothing : certificates[chosen],
        selection.status,
        selection.reason,
        rows,
        pareto,
        memory_model,
        budget,
        resource_model,
        resource_budget,
        objective,
    )
end

function _implementation_selection_data(result::ImplementationSelection)
    data = Dict{String, Any}(
        "schema" => "presage-implementation-selection",
        "schema_version" => 1,
        "status" => string(result.status),
        "reason" => result.reason,
        "spec" => _spec_data(first(result.candidates).plan.spec),
        "pareto_indices" => collect(result.pareto_indices),
        "memory_model" => Dict(
            "depth" => result.memory_model.depth,
            "word_bits" => result.memory_model.word_bits,
        ),
        "selection_policy" => Dict{String, Any}(
            "objective" => string(result.objective),
            "order" => [
                string.(_sweep_selection_order(result.objective, result.resource_model))...,
                "request_index",
            ],
            "resource_budget" => _resource_budget_data(result.resource_budget),
        ),
    )
    result.selected_index === nothing || (data["selected_index"] = result.selected_index)
    result.max_table_blocks === nothing || (
        data["selection_policy"]["max_table_blocks"] =
            _sweep_integer_data(result.max_table_blocks)
    )
    result.resource_model === nothing ||
        (data["resource_model"] = _resource_model_data(result.resource_model))
    data["candidates"] = map(collect(result.rows)) do row
        certificate = row.attempt.certificate
        item = Dict{String, Any}(
            "index" => row.index,
            "implementation" => string(row.implementation),
            "status" => string(row.attempt.status),
            "reason" => row.attempt.reason,
            "certificate" => _certificate_data(certificate),
            "selection_eligible" => false,
        )
        if row.attempt.status == :certified
            costs = _sweep_metrics(row, result.memory_model, result.resource_model)
            item["cost"] = Dict(
                string(k) =>
                    v === nothing ? "unknown" :
                    k == :total_bound ? _rational_text(v) : _sweep_integer_data(v)
                for (k, v) in pairs(costs)
            )
            reasons = _sweep_eligibility(
                costs,
                result.max_table_blocks,
                result.objective,
                result.resource_model,
                result.resource_budget,
            )
            item["selection_eligible"] = isempty(reasons)
            isempty(reasons) || (item["selection_reasons"] = reasons)
        end
        item
    end
    return data
end

"""Write selection assumptions, every candidate's certificate/costs and the decision."""
write_implementation_report(io::IO, result::ImplementationSelection) =
    TOML.print(io, _implementation_selection_data(result); sorted = true)
write_implementation_report(io::IO, result::PolynomialSweepResult) =
    write_sweep_report(io, result)
write_implementation_report(path::AbstractString, result; kwargs...) =
    open(io -> write_implementation_report(io, result; kwargs...), path, "w")
