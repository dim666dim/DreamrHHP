using Distributions
#=
This script generates episodes for cars with no misses and bounded delays (of unknown bounds)
It assumes that the environment is [-1,-1] to [1,1] and the start position of the drone is always
# [0,0]. The goal is generated randomly and is always at least 1 unit away.
The car routes are generated by randomly sampling two points at least 1 unit away from each other
and then the route is either the straight line between them or an L-shaped route.
The episode is always 30 minutes long and each epoch is of 5 seconds (but these parameters can
be changed). Thus each episode has 360 epochs
The range of cars in the episode is specified as a command line argument. Roughly 2/3rds of the cars
are introduced in the first 10 minutes, 1/6th of the cars in the next 10 minutes, and 1/6th of the cars
in the final 10 minutes.
=#
const AVG_ROUTE_DURATION = 1200.0 # seconds
const AVG_ROUTE_WAYPOINTS = 20
const EPISODE_DURATION = 1800.0
const EPOCH_DURATION = 5.0
const START_GOAL_MINDIST = 1.0
const ROUTE_MIN_LENGTH = 1.4159
const STRAIGHT_ROUTE_PROB = 0.75 # Probability that car route will be a straight line, else L shaped
const MODIFY_WAYPT_PROB = 0.3



function inside_grid(p::SVector{2,Float64})
    if p[1] <= -1.0 || p[1] >= 1.0 || p[2] <= -1.0 || p[2] >= 1.0
        return false
    return true
end

function point_dist(p1::SVector{2,Float64}, p2::SVector{2,Float64})
    return sqrt((p1[1] - p2[1])^2 + (p1[2] - p2[2])^2)
end

function rand_unif_grid_pt(rng::RNG=Base.GLOBAL_RNG) where {RNG <: AbstractRNG}
    return SVector{2, Float64}(rand(rng,Uniform(-1.0,1.0)), rand(rng,Uniform(-1.0,1.0)))
end

function interpolate_points_on_line(first_pos::SVector{2,Float64}, last_pos::SVector{2,Float64}, num_pts::Int)

    line_pts = Vector{SVector{2,Float64}}(num_pts)
    x_pts = linspace(first_pos[1], last_pos[1], num_pts)
    y_pts = linspace(first_pos[2], last_pos[2], num_pts)

    for i = 1:num_pts
        line_pts[i] = SVector{2,Float64}(x_pts[i], y_pts[i])
    end

    return line_pts
end

# This is always for the about-to-happen epoch so time was advanced prior to this
function perturb_car_route_times!(curr_time::Float64, car_route_dict::Dict, perturb_prob::Float64=MODIFY_WAYPT_PROB, rng::RNG=Base.GLOBAL_RNG) where {RNG <: AbstractRNG}

    # Modify each way point expected time with the probability
    route = car_route_dict["route"]

    for (idx,timept) in route
        if rand(rng) < perturb_prob && (timept[2]-curr_time) > 2.0*EPOCH_DURATION
            timept[2] = timept[2] + rand(rng,Uniform(-EPOCH_DURATION, EPOCH_DURATION))
        end
    end

end

# simulates the new position of the car
# based on current position and average speed
# I.E. the delays incorporate the speedup etc
# If car crosses the next waypoint, remove the waypoint from the dict
function advance_car_with_epoch!(car_route_dict::Dict(), avg_car_speed::Float64)
end

# Generates 'pos' and 'route' for the first epoch that a car is active
function generate_initial_car_route(start_time::Float64, rng::RNG=Base.GLOBAL_RNG) where {RNG <: AbstractRNG}

    car_start_pos = rand_unif_grid_pt(rng)

    car_goal_pos = rand_unif_grid_pt(rng)
    while point_dist(car_start_pos, car_goal_pos) < ROUTE_MIN_LENGTH
        car_goal_pos = rand_unif_grid_pt(rng)
    end

    route_duration = rand(rng,Uniform(0.85*AVG_ROUTE_DURATION, 1.15*AVG_ROUTE_DURATION))

    avg_speed = point_dist(car_start_pos, car_goal_pos)/route_duration

    route_num_waypts = convert(Int,rand(rng,Uniform(0.75*AVG_ROUTE_WAYPOINTS, 1.25*AVG_ROUTE_WAYPOINTS)))

    route_dict = Dict("pos"=>car_start_pos,"route"=>Dict())

    if rand(rng) < STRAIGHT_ROUTE_PROB
        # Straight line route
        route_waypts = interpolate_points_on_line(car_start_pos, car_goal_pos, route_num_waypts+1)

        for i = 1:route_num_waypts
            # Assume uniformly spread for now
            route_dict["route"][i] = [route_waypts[i+1],start_time + i*(route_duration/route_num_waypts)]
        end

        perturb_car_route_times!(start_time, route_dict, 1.0)
    end

    return route_dict, avg_speed
end    


function generate_episode_dict_unitgrid(min_cars::Int, max_cars::Int,rng::RNG=Base.GLOBAL_RNG) where {RNG <: AbstractRNG}

    num_epochs = convert(Int64,(EPISODE_DURATION/EPOCH_DURATION))

    # Start is always 0.0
    start_pos = SVector{2,Float64}(0.0,0.0)

    # Generate goal as a random 2D point at least 1 unit away from start
    goal_pos = rand_unif_grid_pt(rng)
    while point_dist(start_pos, goal_pos) < START_GOAL_MINDIST
        goal_pos = rand_unif_grid_pt(rng)
    end

    # Initialize episode_dict
    episode_dict = Dict("num_epochs"=>num_epochs, "start_pos"=>start_pos, "goal_pos"=>goal_pos, "epochs"=>Dict())

    epoch_time = 0.0

    for epoch_idx = 1:num_epochs