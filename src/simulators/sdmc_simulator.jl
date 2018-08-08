mutable struct SDMCState{US <: UAVState}
    uav_state::US
    on_car::Bool
    car_id::String
end

SDMCAction = Union{UA,Tuple{HOP_ACTION,String}} where {UA <: UAVAction}


mutable struct SDMCSimulator{RNG <: AbstractRNG, UDM <: UAVDynamicsModel}
    epochs_dict::Dict
    uav_dynamics::UDM
    state::SDMCState
    goal_pos::Point
    epoch_counter::Int64
    rng::RNG
end


function SDMCSimulator(epochs_dict::Dict, uav_dynamics::UDM, start_pos::Point, goal_pos::Point, rng::RNG=Base.GLOBAL_RNG) where {RNG <: AbstractRNG, UDM <: UAVDynamicsModel}

    # Get start state
    state::SDMCState = SDMCState(get_state_at_rest(uav_dynamics, start_pos), false, "")

    return SDMCSimulator(epochs_dict, uav_dynamics, state, goal_pos, 0, rng)
end

function get_epoch0_dict(sdmc::SDMCSimulator)
    return sdmc.epochs_dict["0"]
end


function step_SDMC(sdmc::SDMCSimulator, action::SDMCAction)

    # Increase Counter
    sdmc.epoch_counter += 1

    # Read in next epoch
    epoch_info_dict = sdmc.epochs_dict[string(sdmc.epoch_counter)]
    epoch_car_info = epoch_info_dict["car-info"]

    reward::Float64 = -TIME_COEFFICIENT*MDP_TIMESTEP

    # If UAV action, simulate and add reward and return car dict as additional info (OpenAIGYM style)
    if typeof(action) <: UAVAction
        new_uavstate = next_state(sdmc.uav_dynamics, sdmc.state.uav_state, action, sdmc.rng)
        reward += -dynamics_cost(sdmc.uav_dynamics, sdmc.state.uav_state, new_uavstate)
        sdmc.state.uav_state = new_uavstate # Update system state
    else
        if action[1] == HOPON

            # Must not be on a car currently
            if sdmc.state.on_car == true
                warn("Cannot Hop On while on a car!")
                reward += -INVALID_ACTION_PENALTY
            else
                prev_epoch_car_info = sdmc.epochs_dict[string(sdmc.epoch_counter-1)]["car-info"]
                next_epoch_car_info = sdmc.epochs_dict[string(sdmc.epoch_counter+1)]["car-info"]

                hopon_car_id = action[2]

                car_pos::Point = Point(epoch_car_info[hopon_car_id]["pos"][1],epoch_car_info[hopon_car_id]["pos"][2])
                prev_car_pos::Point = Point(prev_epoch_car_info[hopon_car_id]["pos"][1],prev_epoch_car_info[hopon_car_id]["pos"][2])
                next_car_pos::Point = Point(next_epoch_car_info[hopon_car_id]["pos"][1],next_epoch_car_info[hopon_car_id]["pos"][2])

                uav_pos::Point = Point(sdmc.state.uav_state.x, sdmc.state.uav_state.y)

                # println(car_pos)
                # println(prev_car_pos)
                # println(next_car_pos)

                # println(uav_pos)

                curr_speed = sqrt(sdmc.state.uav_state.xdot^2 + sdmc.state.uav_state.ydot^2)
                
                dist = min(point_dist(car_pos, uav_pos), point_dist(prev_car_pos,uav_pos), point_dist(next_car_pos,uav_pos))

                if dist < HOP_DISTANCE_THRESHOLD*MDP_TIMESTEP && curr_speed < XYDOT_HOP_THRESH
                    warn("Successful hop on to ",hopon_car_id, "at epoch ",sdmc.epoch_counter)
                    curr_car_pos = Point(epoch_car_info[hopon_car_id]["pos"][1],epoch_car_info[hopon_car_id]["pos"][2])
                    sdmc.state.uav_state = get_state_at_rest(sdmc.uav_dynamics, curr_car_pos)
                    sdmc.state.on_car = true
                    sdmc.state.car_id = hopon_car_id
                else
                    warn("Too far from car to hop on!")
                    # println("PREV CAR POS - ",prev_car_pos)
                    # println("CAR POS - ",car_pos)
                    # println("NEXT CAR POS - ",next_car_pos)
                    # println("Distance is ",dist," and speed is ",curr_speed)
                    reward += -INVALID_ACTION_PENALTY
                end
            end
        elseif action[1] == STAY

            # Must be on a car currently
            if sdmc.state.on_car == false
                warn("Cannot Stay when not on car!")
                reward += -INVALID_ACTION_PENALTY
            else
                # Assign new location to uav
                current_car = sdmc.state.car_id
                curr_car_pos = Point(epoch_car_info[current_car]["pos"][1],epoch_car_info[current_car]["pos"][2])
                sdmc.state.uav_state = get_state_at_rest(sdmc.uav_dynamics, curr_car_pos)
            end

        else
            # Must be HOPOFF
            if sdmc.state.on_car == false
                warn("Cannot Hop Off when not on car!")
                reward += -INVALID_ACTION_PENALTY
            else
                warn("Successful hopoff from car ",sdmc.state.car_id, " at epoch ",sdmc.epoch_counter)
                current_car = sdmc.state.car_id
                curr_car_pos = Point(epoch_car_info[current_car]["pos"][1],epoch_car_info[current_car]["pos"][2])
                sdmc.state.uav_state = get_state_at_rest(sdmc.uav_dynamics, curr_car_pos)
                sdmc.state.on_car = false
                sdmc.state.car_id = ""
            end
        end
    end

    is_terminal::Bool = false

    curr_speed = sqrt(sdmc.state.uav_state.xdot^2 + sdmc.state.uav_state.ydot^2)

    # Check if at goal
    if point_dist(Point(sdmc.state.uav_state.x, sdmc.state.uav_state.y), sdmc.goal_pos) < MDP_TIMESTEP*HOP_DISTANCE_THRESHOLD && curr_speed < XYDOT_HOP_THRESH
        is_terminal = true
    end

    return sdmc.state, reward, is_terminal, epoch_info_dict

end