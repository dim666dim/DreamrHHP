mutable struct AStarStates{D<:Number,Heap,H}
    parent_indices::Vector{Int}
    dists::Vector{D}
    colormap::Vector{Int}
    heap::Heap
    hmap::Vector{H}
end

struct AStarHEntry{D <: Number}
    vIdx::Int
    gvalue::D
    fvalue::D
end

function Base.isless(e1::AStarHEntry, e2::AStarHEntry)
    return e1.fvalue < e2.fvalue
end

# create Astar states

function create_astar_states(g::AbstractGraph{V}, ::Type{D}) where {V, D <: Number}
    n = num_vertices(g)
    parent_indices = zeros(Int, n)
    dists = fill(typemax(D), n)
    colormap = zeros(Int, n)
    heap = mutable_binary_minheap(AStarHEntry{D})
    hmap = zeros(Int, n)

    return AStarStates(parent_indices, dists, colormap, heap, hmap)
end

function set_source!(state::AStarStates{D}, g::AbstractGraph{V}, s::Int) where {D <: Number, V}
    state.parent_indices[s] = s
    state.dists[s] = 0
    state.colormap[s] = 2
end

function process_neighbors_implicit(
    state::AStarStates{D,Heap,H},
    graph::AbstractGraph{V},
    edge_wt_fn::Function,
    neighbors::Vector{Int},
    u::Int, du::D, visitor::AbstractDijkstraVisitor,
    heuristic::Function) where {V, D <: Number, Heap, H}

    dv::D = zero(D)

    for iv in neighbors
        v_color::Int = state.colormap[iv]

        if v_color == 0
            state.dists[iv] = dv = du + edge_wt_fn(graph.vertices[u], graph.vertices[iv])
            state.parent_indices[iv] = u
            state.colormap[iv] = 1
            Graphs.discover_vertex!(visitor, graph.vertices[u], graph.vertices[iv], dv)

            state.hmap[iv] = push!(state.heap, AStarHEntry(iv, dv, dv + heuristic(graph.vertices[iv])))

        elseif v_color == 1
            dv = du + edge_wt_fn(graph.vertices[u], graph.vertices[iv])
            if dv < state.dists[iv]
                state.dists[iv] = dv
                state.parent_indices[iv] = u

                Graphs.update_vertex!(visitor, graph.vertices[u], graph.vertices[iv], dv)
                update!(state.heap, state.hmap[iv], AStarHEntry(iv, dv, dv + heuristic(graph.vertices[iv])))
            end
        end
    end
end


function astar_light_shortest_path_implicit!(
    graph::AbstractGraph{V},                # the graph
    edge_wt_fn::Function, # distances associated with edges
    source::Int,             # the source
    visitor::AbstractDijkstraVisitor,# visitor object
    heuristic::Function,      # Heuristic function for vertices
    state::AStarStates{D,Heap,H}) where {V, D <: Number, Heap, H}

    @graph_requires graph vertex_map vertex_list

    d0 = zero(D)
    set_source!(state, graph, source)

    source_nbrs = Vector{Int}()

    if !Graphs.include_vertex!(visitor, graph.vertices[source], graph.vertices[source], d0, nbrs)
        return state
    end

    process_neighbors_implicit!(state, graph, edge_wt_fn, source_nbrs, source, d0, visitor, heuristic)
    Graphs.close_vertex!(visitor, graph.vertices[source])

    while !isempty(state.heap)

        # pick next vertex to include
        entry = pop!(state.heap)
        ui::Int = entry.vIdx
        du::D = entry.gvalue

        state.colormap[ui] = 2

        nbrs = Vector{Int}()

        if !Graphs.include_vertex!(visitor, graph.vertices[state.parent_indices[ui]], graph.vertices[ui], du, nbrs)
            return state
        end

        # process u's neighbors

        process_neighbors_implicit!(state, graph, edge_wt_fn, nbrs, ui, d0, visitor, heuristic)
        Graphs.close_vertex!(visitor, u)
    end

    state
end

function astar_shortest_path_implicit(
    graph::AbstractGraph{V},                # the graph
    edge_wt_fn::Function, # distances associated with edges
    source::Int,
    visitor::AbstractDijkstraVisitor,
    heuristic::Function = n -> 0,
    ::Type{D} = Float64) where {V, D <: Number}
    state = create_astar_states(graph, D)
    astar_shortest_path_implicit!(graph, edge_wt_fn, source, visitor, heuristic, state)
end