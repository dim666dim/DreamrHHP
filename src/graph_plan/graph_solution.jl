# This is a general graph solution object
# It has methods for updating all car route vertices
# and replanning from a certain vertex in the graph.
# At the beginning, drone vertices are only the initial time start and the
# time-unconstrained goal vertex but other drone vertices may be added at an
# intermediate stage, especially when lower level policies are aborted
# TODO : Use IncidenceList or Graph?
mutable struct GraphSolution
    car_map::Dict{String,Car}
    drone::Drone
    max_car_speed::Float64
    goal_idx::Int
    next_start_idx::Int
    n_vertices::Int
    curr_time::Float64
    car_drone_graph::SimpleVListGraph{CarDroneVertex}
    route_vert_id_to_idx::Dict{String,Int}
    flight_edge_wts::Dict{Tuple{Int,Int},Float64}
    curr_soln_idx_path::Vector{Int}
    curr_best_soln_value::Float64
end

function GraphSolution(_drone::Drone, _max_car_speed::Float64)
    # define car_drone_graph
    car_drone_graph = SimpleVListGraph(CarDroneVertex[], is_directed=true)

    return GraphSolution(Dict{String,Car}(), _drone, 
        _max_car_speed, 0, 0, 0, 0, 0.0, car_drone_graph, 
        Dict{String,Int}(), Dict{Tuple{Int,Int},Float64}(),
        Int[], Inf)
end

# Initialize graph for first epoch
# Assume that updates to successive epochs are only in car_routes
function setup_graph(gs::GraphSolution, start_pos::Point, goal_pos::Point, epoch1::Dict, start_time::Float64=0.0, goal_time::Float64=Inf)

    # Set current time
    gs.curr_time = convert(Float64, epoch1["time"])

    # Initialize start vertex
    gs.n_vertices += 1
    add_vertex!(gs.car_drone_graph, CarDroneVertex(gs.n_vertices, start_pos, start_time,false))
    gs.next_start_idx = gs.n_vertices

    # Initialize goal vertex
    gs.n_vertices += 1
    add_vertex!(gs.car_drone_graph, CarDroneVertex(gs.n_vertices, goal_pos, goal_time,false))
    gs.goal_idx = gs.n_vertices

    # Now add vertices for car route
    # NOTE - Ordering of cars is immaterial here
    epoch_cars = epoch1["car-info"]
    for (car_id, car_info) in epoch_cars

        route_info = car_info["route"]

        # First add vertices if there are any
        if route_info != nothing
            # Next route vertex is the first
            first_route_idx = gs.n_vertices+1

            # NOTE - parse here done for floating points so that intermediate points can be inserted later
            for (id, timept) in sort(collect(route_info),by=x->parse(Float64, x[1]))
                gs.n_vertices += 1
                add_vertex!(gs.car_drone_graph, CarDroneVertex(gs.n_vertices, Point(timept[1][1], timept[1][2]), timept[2]), true)
                route_vert_id_to_idx[string(car_id,"-",id)] = gs.n_vertices
            end

            last_route_idx = gs.n_vertices

            # Now add appropriate car object
            gs.car_map[car_id] = Car(Point(car_info["pos"][1], car_info["pos"][2]), (first_route_idx, last_route_idx))
            debug("Car ",car_id," has been added!")
        else
            # Add inactive car - this should not happen at first epoch though
            warn("Inactive Car ",car_id," in first epoch!")
            gs.car_map[car_id] = Car(Point(),0,0,1,false)
        end
    end
end


function update_cars_with_epoch(gs::GraphSolution, epoch::Dict)

    # Set current time
    gs.curr_time = convert(Float64, epoch["time"])

    # Iterate over cars, add if new or update if old
    epoch_cars = epoch["car-info"]

    for (car_id, car_info) in epoch_cars

        # Update car route if it exists
        if haskey(gs.car_map, car_id)

            this_car = gs.car_map[car_id]
            route_info = car_info["route"]

            if route_info != nothing

                # Update current car position
                this_car.curr_pos = Point(car_info["pos"][1], car_info["pos"][2])

                # Update times of all future vertices
                # NOTE - This assumes no new vertices added (for now)
                sorted_route = sort(collect(route_info), by=x->parse(Float64, x[1]))
                for (id, timept) in sorted_route
                    # TODO: Check for equality of points?
                    gs.vertices[route_vert_id_to_idx[string(car_id,"-",id)]].time_stamp = timept[2]
                end

                # Check if the next waypoint of route has been updated
                first_route_idx = route_vert_id_to_idx[string(car_id,"-",sorted_route[1][1])]
                if this_car.route_idx_range[1] != first_route_idx
                    debug("Car ",car_id," has updated its next route point to ",id)
                    this_car.route_idx_range[1] = first_route_idx
                end
            else
                # Car has become inactive
                debug("Car ",car_id," has become inactive!")
                this_car.active = false
            end
        else
            # New car - add as above
            route_info = car_info["route"]

            if route_info != nothing
                first_route_idx = gs.n_vertices+1

                for (id, timept) in sort(collect(route_info),by=x->parse(Float64, x[1]))
                    gs.n_vertices += 1
                    add_vertex!(gs.car_drone_graph, CarDroneVertex(gs.n_vertices, Point(timept[1][1], timept[1][2]), timept[2]), true)
                    route_vert_id_to_idx[string(car_id,"-",id)] = gs.n_vertices
                end

                last_route_idx = gs.n_vertices

                gs.car_map[car_id] = Car(Point(car_info["pos"][1], car_info["pos"][2]), (first_route_idx, last_route_idx))
                debug("Car ",car_id," has been added!")
            else
                # Add inactive car - this should not happen at first epoch though
                warn("Inactive Car ",car_id," in its first epoch!")
                gs.car_map[car_id] = Car(Point(),0,0,1,false)
            end
        end
    end
end

# Add a new vertex and return index of it
function add_drone_vertex(gs::GraphSolution, pos::Point, time_stamp::Float64)
    gs.n_vertices += 1
    add_vertex!(gs.car_drone_graph, CarDroneVertex(gs.n_vertices, pos, time_stamp), false)
    return gs.n_vertices
end

# Add a new vertex and make that the new start index
function add_updated_start(gs::GraphSolution, pos::Point, time_stamp::Float64)
    gs.next_start_idx = add_drone_vertex(gs, pos, time_stamp)
end


function astar_heuristic(gs::GraphSolution. v::CarDroneVertex)
    return TIME_COEFFICIENT*point_dist(v.pos, gs.car_drone_graph.vertices[gs.goal_idx])/gs.max_car_speed
end


function edge_weight_function_recompute(flightedge_wt_fn::Function, gs::GraphSolution, u::CarDroneVertex, v::CarDroneVertex)
    if u.is_car && v.is_car
        return coast_edge_cost(u,v)
    else if !v.is_car # Flight edge
        return flight_edge_cost_nominal(u,v)
    else
        return flightedge_wt_fn(u,v,gs.drone)
    end
end


# TODO - Should coast edge also use value function????
function edge_weight_function_lookup(flightedge_wt_fn::Function, gs::GraphSolution, u::CarDroneVertex, v::CarDroneVertex)
    if u.is_car && v.is_car
        return coast_edge_cost(u,v)
    else if !v.is_car # Flight edge
        return flight_edge_cost_nominal(u,v)
    else
        # Unconstrained flight edge
        edge_weight_val = get(gs.flight_edge_wts, (u,v), Inf)
        if edge_weight_val == Inf
            # Not present - compute weight and update
            edge_weight_val = flightedge_wt_fn(u,v,gs.drone)
            gs.flight_edge_wts[(u,v)] = edge_weight_val
        else
            # If either vertex time has changed significantly, update both and recompute
            if abs(u.time_stamp - u.last_time_stamp) > WAYPT_TIME_CHANGE_THRESHOLD
                || abs(v.time_stamp - v.last_time_stamp) > WAYPT_TIME_CHANGE_THRESHOLD
                u.last_time_stamp = u.time_stamp
                v.last_time_stamp = v.time_stamp
                edge_weight_val = flightedge_wt_fn(u,v,gs.drone)
                gs.flight_edge_wts[(u,v)] = edge_weight_val
            end
        end

        # Return the appropriate value
        return edge_weight_val
    end
end


# Need a function for NEXT MACRO_ACTION - so Next segment where mode changes!
# 


# Whatever the next replan start vertex is, plan from it towards goal
function plan_from_next_start(gs::GraphSolution, flightedge_wt_fn::Function)

    # Set up heuristic and edge_weight_functions
    # TODO : What's the right way to just do this once?
    heuristic(v) = astar_heuristic(gs, v)
    edge_wt_fn(u,v) = edge_weight_function(flightedge_wt_fn, gs.drone, u, v)

    astar_path_soln = astar_shortest_path_implicit(gs.car_drone_graph,edge_wt_fn,gs.next_start_idx,GoalVisitorImplicit(gs),heuristic)

    # Obtain path and its current cost
    # This is the best path regardless. DON'T NEED TO RECOMPUTE OLD PATH
