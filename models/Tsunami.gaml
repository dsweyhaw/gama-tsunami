model tsunami

// Define the grid first, before global
grid cell_grid width: 100 height: 100 neighbors: 8 {
    bool is_land <- false;
    bool is_road <- false;
    bool is_flooded <- false;
    int shelter_id <- -1;
    float distance_to_safezone <- float(100000.0);
    rgb color <- ocean_color;
    float flood_intensity <- 0.0;
    
    aspect default {
        draw shape color: is_flooded ? rgb(0, 0, 255, flood_intensity) : color border: #black;
    }
}

global {
    // GIS and data files
    file building_shapefile <- file("../includes/buildings.shp");
    file road_shapefile <- file("../includes/roads.shp");
    file shelter_csvfile <- csv_file("../includes/shelters.csv", ",");
    
    // Image files for species
    file car_icon <- file("../includes/car-2897.png");
    file boat_icon <- file("../includes/ship-1051.png");
    
    // Environment parameters
    geometry shape <- envelope(building_shapefile);
    geometry land_area;
    geometry valid_area;
    
    // Lists for shelter management
    list<point> shelter_locations;
    list<float> shelter_capacities;
    list<int> current_shelter_occupancy;
    
    // Global parameters
    float max_distance_shelter <- 100000.0;
    int people_patch_threshold <- 10;  // max number of people per patch
    
    // Speed parameters (in m/s)
    float human_speed_avg <- 5.6;  // 20 km/h average human speed
    float human_speed_min <- 5.6;  // Minimum speed
    float human_speed_max <- 10.0; // 36 km/h maximum speed (running)
    
    // Population counts and sizes
    int locals_number <- 100;
    float locals_size <- 4.0;
    
    int tourists_number <- 50;
    float tourists_size <- 4.0;
    
    int rescuers_number <- 20;
    float rescuers_size <- 4.0;
    
    // Status counts for each population
    int locals_safe <- 0;
    int locals_dead <- 0;
    int locals_in_danger <- 0;
    
    int tourists_safe <- 0;
    int tourists_dead <- 0;
    int tourists_in_danger <- 0;
    
    int rescuers_safe <- 0;
    int rescuers_dead <- 0;
    int rescuers_in_danger <- 0;
    
    // Tourist strategy parameter
    string tourist_strategy <- "following rescuers or locals" among: ["wandering", "following rescuers or locals", "following crowd"];
    
    // Following crowd parameters
    float crowd_search_angle <- 45.0;  // Angle increment for crowd searching (degrees)
    float crowd_centroid_distance <- 7.5;  // Half of radius_look
    float crowd_centroid_radius <- 7.5;   // Half of radius_look
    
    // Tsunami parameters
    float tsunami_speed <- 44.3;  // m/s (sqrt(200*9.8) for shallow water)
    int tsunami_approach_time <- 460; // seconds (2 hours from Manila Trench to central VN)
    geometry tsunami_front;
    float coastal_x_coord;
    
    // Tsunami visualization parameters
    float wave_width <- 50.0; // Width of the visible wave effect
    geometry tsunami_shape;
    list<geometry> flood_areas;
    
    // Color parameters
    rgb land_color <- rgb(204, 175, 139);  // Light brown for land
    rgb ocean_color <- rgb(135, 206, 235);  // Light blue for ocean
    rgb road_color <- rgb(71, 71, 71);      // Dark grey for roads
    
    // Car parameters
    float car_speed_min <- 15.0;  // m/s (54 km/h)
    float car_speed_max <- 25.0;  // m/s (90 km/h)
    float car_acceleration <- 5.0;
    float car_deceleration <- 5.0;
    int cars_threshold_wait <- 5;
    string car_strategy <- "always go ahead" among: ["always go ahead", "go out when congestion"];
    
    // Car counters
    int cars_safe <- 0;
    int cars_dead <- 0;
    int cars_in_danger <- 0;
    int cars_number <- 10;
    rgb cars_safe_color <- #green;
    rgb cars_dead_color <- #red;
    rgb cars_in_danger_color <- #brown;
    
    // Boat parameters
    float boat_speed_min <- 2.0;  // m/s
    float boat_speed_max <- 10.0; // m/s
    float boat_rescue_radius <- 20.0;
    int boat_capacity <- 20;
    int boats_number <- 5;
    
    // Boat counters
    int boats_safe <- 0;
    int boats_dead <- 0;
    int boats_in_danger <- 0;
    
    // Car initialization
    action init_cars {
        create car number: cars_number {
            location <- any_location_in(one_of(road));
            cars_in_danger <- cars_in_danger + 1;
        }
    }
    
    // Boat initialization
    action init_boats {
        create boat number: boats_number {
            // Place boats in water areas
            point water_loc <- one_of(cell_grid where (!each.is_land)).location;
            location <- water_loc;
            boats_in_danger <- boats_in_danger + 1;
        }
    }
    
    // Add to global section
    int update_frequency <- 1; // Update every cycle by default
    
    // Add these variables to the global section
    bool simulation_complete <- false;
    int post_tsunami_delay <- 100; // Cycles to continue after tsunami passes through
    
    init {
        // Create physical environment first
        create building from: building_shapefile {
            shape <- shape; 
        }
        create road from: road_shapefile;
        
        // Define land area (union of buildings and roads)
        land_area <- union(building collect each.shape, road collect each.shape);
        valid_area <- land_area;
        
        // Initialize water/land areas
        loop c over: cell_grid {
            if (c.shape intersects land_area) {
                c.color <- land_color;
                c.is_land <- true;
            } else {
                c.color <- ocean_color;
                c.is_land <- false;
            }
        }
        
        // Draw roads on top
        ask road {
            color <- road_color;
        }
        
        // Draw buildings on top
        ask building {
            color <- rgb(120, 120, 120);  // Grey for buildings
        }
        
        // Initialize shelter system from CSV using exact coordinates
        matrix data <- matrix(shelter_csvfile);
        loop i from: 0 to: data.rows - 1 {
            create shelter {
                location <- {float(data[0,i]), float(data[1,i])};
                width <- float(data[2,i]);
                height <- float(data[3,i]);
                capacity <- float(data[4,i]);
                name <- string(data[5,i]);
                current_occupants <- 0;
            }
        }
        
        // Create initial populations
        create people number: locals_number {
            type <- "local";
            color <- #yellow;
            agent_size <- locals_size;
            speed <- rnd(human_speed_min, human_speed_max);
            is_safe <- false;
            is_dead <- false;
            location <- any_location_in(one_of(road));
        }
        
        create people number: tourists_number {
            type <- "tourist";
            color <- #violet;
            agent_size <- tourists_size;
            speed <- rnd(human_speed_min, human_speed_max);
            is_safe <- false;
            is_dead <- false;
            radius_look <- 15.0 + rnd(-2.0, 2.0);
            leader <- nil;
            location <- any_location_in(one_of(road));
        }
        
        create people number: rescuers_number {
            type <- "rescuer";
            color <- #turquoise;
            agent_size <- rescuers_size;
            speed <- rnd(human_speed_min, human_speed_max);
            is_safe <- false;
            is_dead <- false;
            radius_look <- 15.0 + rnd(-2.0, 2.0);
            nb_tourists_to_rescue <- 0;
            location <- any_location_in(one_of(road));
        }
        
        // Initialize tsunami parameters
        coastal_x_coord <- max(building collect each.location.x);
        tsunami_front <- square(1) at_location {max(world.shape.width * 1.2, coastal_x_coord + 500), world.shape.height/2};
        tsunami_shape <- rectangle(wave_width, world.shape.height) at_location {max(world.shape.width * 1.2, coastal_x_coord + 500), world.shape.height/2};
        flood_areas <- [];
        
        // Initialize cars
        do init_cars();
        
        // Initialize boats
        do init_boats();
    }
    
    reflex update_tsunami when: cycle >= tsunami_approach_time {
        // Update tsunami position
        float tsunami_movement <- tsunami_speed * step;
        tsunami_front <- tsunami_front translated_by {-tsunami_movement, 0};
        tsunami_shape <- tsunami_shape translated_by {-tsunami_movement, 0};
        
        // Update flooding visualization
        ask cell_grid overlapping tsunami_shape {
            if !is_flooded {
                is_flooded <- true;
                flood_intensity <- 0.3;
            }
        }
        
        // Increase flood intensity for previously flooded cells
        ask cell_grid where (each.is_flooded) {
            flood_intensity <- min([1.0, flood_intensity + 0.01]);
        }
        
        // Update road flooding using proper GAMA spatial operators
        ask road where (each.shape intersects tsunami_shape) {
            is_flooded <- true;
            color <- rgb(0,0,255,0.8);
        }
    }
    
    // Add this reflex to check if tsunami has moved through the entire map
    reflex check_tsunami_end when: cycle >= tsunami_approach_time and not simulation_complete {
        // Check if tsunami has reached the leftmost edge of the map
        float leftmost_x <- min(cell_grid collect each.location.x);
        
        // Check if tsunami has passed through the map 
        bool tsunami_passed_left_edge <- false;
        if (tsunami_shape != nil and tsunami_shape.location.x <= leftmost_x) {
            tsunami_passed_left_edge <- true;
        }
        
        // Alternative method: Check if tsunami location is beyond leftmost edge
        if (tsunami_front != nil and tsunami_front.location.x <= leftmost_x) {
            tsunami_passed_left_edge <- true;
        }
        
        // If tsunami has passed through the map
        if (tsunami_passed_left_edge) {
            // Let simulation run for a short time after tsunami passes to allow agents to react
            if (cycle >= tsunami_approach_time + post_tsunami_delay) {
                write "SIMULATION COMPLETE: Tsunami has passed through the map";
                simulation_complete <- true;
                do pause; // This will pause the simulation
            }
        }
    }
}

// Species definitions
species building {
    aspect default {
        draw shape color: #gray border: #black;
    }
}

species road {
    bool is_flooded <- false;
    
    aspect default {
        draw shape color: is_flooded ? rgb(0,0,255,0.8) : road_color width: 2.0;
    }
}

species shelter {
    float width;
    float height;
    float capacity;
    string name;
    int current_occupants;
    
    aspect default {
        draw circle(100) color: rgb(0,255,0,0.6) border: #black width: 2;
        draw triangle(100) color: #white border: #black;
        draw name size: 14 color: #black at: {location.x, location.y + 120};
    }
}

// Base species for all people (locals, tourists, rescuers)
species people skills: [moving] {
    string type;
    rgb color;
    float speed;
    bool is_safe;
    bool is_dead;
    float radius_look;
    people leader <- nil;
    int nb_tourists_to_rescue;
    float agent_size;
    
    bool is_valid_location(point new_loc) {
        return (valid_area covers new_loc) and 
               (cell_grid closest_to new_loc).is_land and 
               (shape intersects land_area);
    }
    
    // Death checking reflex - runs every step
    reflex check_death when: !is_dead and !is_safe {
        // Check if current location is flooded using proper GAMA spatial operators
        road current_road <- road closest_to self;
        if (current_road != nil and current_road.is_flooded) {
            is_dead <- true;
            color <- #red;
            
            // Update death counters based on agent type
            switch type {
                match "local" { 
                    locals_dead <- locals_dead + 1;
                    locals_in_danger <- locals_in_danger - 1;
                }
                match "tourist" { 
                    tourists_dead <- tourists_dead + 1;
                    tourists_in_danger <- tourists_in_danger - 1;
                }
                match "rescuer" { 
                    rescuers_dead <- rescuers_dead + 1;
                    rescuers_in_danger <- rescuers_in_danger - 1;
                }
            }
        }
    }
    
    // Safety checking reflex - runs every step
    reflex check_safety when: !is_dead and !is_safe {
        shelter closest_shelter <- shelter closest_to self;
        
        // Check if agent reached shelter
        if (self distance_to closest_shelter < 10.0) {
            // Check if shelter has capacity
            if (closest_shelter.current_occupants < closest_shelter.capacity) {
                is_safe <- true;
                color <- #green;
                closest_shelter.current_occupants <- closest_shelter.current_occupants + 1;
                location <- closest_shelter.location;
                
                // Update safety counters based on agent type
                switch type {
                    match "local" { 
                        locals_safe <- locals_safe + 1;
                        locals_in_danger <- locals_in_danger - 1;
                    }
                    match "tourist" { 
                        tourists_safe <- tourists_safe + 1;
                        tourists_in_danger <- tourists_in_danger - 1;
                    }
                    match "rescuer" { 
                        rescuers_safe <- rescuers_safe + 1;
                        rescuers_in_danger <- rescuers_in_danger - 1;
                    }
                }
            }
        }
    }
    
    // Different movement behaviors for each type
    reflex move when: !is_dead and !is_safe and (cycle mod update_frequency = 0) {
        switch type {
            match "local" {
                // Randomize speed each step like NetLogo
                speed <- gauss(speed, 1.0);
                if (speed < human_speed_min) { speed <- human_speed_min; }
                if (speed > human_speed_max) { speed <- human_speed_max; }
                
                point target <- (shelter closest_to self).location;
                path path_to_target <- topology(road) path_between (self.location, target);
                
                // Check if path exists and doesn't cross ocean
                if (path_to_target != nil) {
                    // Get next point in the path
                    point next_point <- first(path_to_target.vertices);
                    
                    // Check if next point is on land before moving
                    if ((cell_grid closest_to next_point).is_land) {
                        do follow path: path_to_target speed: speed;
                    } else {
                        // Find a random land direction if path goes through ocean
                        bool found_valid_move <- false;
                        int safety_counter <- 0;
                        int max_safety <- 100; // Safety measure to prevent CPU hogging
                        
                        loop while: (not found_valid_move) {
                            // Try a random direction
                            float random_angle <- rnd(360.0);
                            point possible_move <- self.location + {cos(random_angle) * speed, sin(random_angle) * speed};
                            
                            // Check if the new point is on land
                            if ((cell_grid closest_to possible_move).is_land) {
                                // Try to find a new path from this point
                                location <- possible_move;
                                found_valid_move <- true;
                            }
                            
                            // Safety exit - prevents infinite loops but allows agent to try again next cycle
                            safety_counter <- safety_counter + 1;
                            if (safety_counter >= max_safety) {
                                break; // Exit this loop but the agent will try again next cycle
                            }
                        }
                    }
                }
            }
            match "tourist" {
                if (tourist_strategy = "wandering") {
                    // Try to find a valid location - can try indefinitely
                    bool found_valid_location <- false;
                    int safety_counter <- 0;
                    int max_safety <- 100; // Safety measure to prevent CPU hogging
                    
                    loop while: (not found_valid_location) {
                        // Generate a random possible location
                        point possible_loc <- self.location + {rnd(-5,5) * speed, rnd(-5,5) * speed};
                        
                        // Check if location is valid (on land and within bounds)
                        if (is_valid_location(possible_loc)) {
                            location <- possible_loc;
                            found_valid_location <- true;
                        }
                        
                        // Safety exit - prevents infinite loops but allows agent to try again next cycle
                        safety_counter <- safety_counter + 1;
                        if (safety_counter >= max_safety) {
                            break; // Exit this loop but the agent will try again next cycle
                        }
                    }
                } else if (tourist_strategy = "following rescuers or locals") {
                    if (leader = nil) {
                        list<people> potential_leaders <- (people where (each.type = "rescuer")) at_distance radius_look;
                        if (empty(potential_leaders)) {
                            potential_leaders <- (people where (each.type = "local")) at_distance radius_look;
                        }
                        if (!empty(potential_leaders)) {
                            leader <- potential_leaders[0];
                        }
                    }
                    if (leader != nil) {
                        path path_to_leader <- topology(road) path_between (self.location, leader.location);
                        if (path_to_leader != nil) {
                            do follow path: path_to_leader speed: speed;
                        }
                    } else {
                        point possible_loc <- self.location + {rnd(-1,1) * speed, rnd(-1,1) * speed};
                        if (is_valid_location(possible_loc)) {
                            location <- possible_loc;
                        }
                    }
                } else if (tourist_strategy = "following crowd") {
                    // Initialize variables for crowd search
                    float current_angle <- 0.0;
                    int max_crowd_size <- -1;
                    float best_angle <- -1.0;
                    
                    // Search in 360 degrees with 45-degree increments
                    loop while: current_angle < 360 {
                        point check_point <- self.location + {cos(current_angle) * crowd_centroid_distance, sin(current_angle) * crowd_centroid_distance};
                        
                        if (is_valid_location(check_point)) {
                            // Count people (tourists and locals) in the area
                            int crowd_size <- length(people at_distance crowd_centroid_radius where (each.type in ["tourist", "local"]));
                            
                            // Update best direction if we found more people
                            if (crowd_size > max_crowd_size) {
                                max_crowd_size <- crowd_size;
                                best_angle <- current_angle;
                            }
                        }
                        
                        current_angle <- current_angle + crowd_search_angle;
                    }
                    
                    // Move towards the most crowded direction if found
                    if (best_angle >= 0) {
                        point target <- self.location + {cos(best_angle) * speed, sin(best_angle) * speed};
                        if (is_valid_location(target)) {
                            location <- target;
                        }
                    }
                }
            }
            match "rescuer" {
                // Randomize speed like we do for locals
                speed <- gauss(speed, 1.0);
                if (speed < human_speed_min) { speed <- human_speed_min; }
                if (speed > human_speed_max) { speed <- human_speed_max; }
                
                list<people> nearby_tourists <- (people where (each.type = "tourist" and !each.is_safe)) at_distance radius_look;
                
                if (!empty(nearby_tourists)) {
                    // If tourists found nearby, head to nearest shelter
                    point target <- (shelter closest_to self).location;
                    path path_to_target <- topology(road) path_between (self.location, target);
                    
                    // Use the exact same path checking logic as for locals
                    if (path_to_target != nil and !empty(path_to_target.vertices)) {
                        point next_point <- first(path_to_target.vertices);
                        
                        if ((cell_grid closest_to next_point).is_land) {
                            do follow path: path_to_target speed: speed;
                        } else {
                            // Using same random direction logic as locals for ocean avoidance
                            bool found_valid_move <- false;
                            int safety_counter <- 0;
                            int max_safety <- 100; // Safety measure to prevent CPU hogging
                            
                            loop while: (not found_valid_move) {
                                // Try a random direction like locals do
                                float random_angle <- rnd(360.0);
                                point possible_move <- self.location + {cos(random_angle) * speed, sin(random_angle) * speed};
                                
                                // Check specifically for land, not using is_valid_location
                                if ((cell_grid closest_to possible_move).is_land) {
                                    location <- possible_move;
                                    found_valid_move <- true;
                                }
                                
                                // Safety exit - prevents infinite loops but allows agent to try again next cycle
                                safety_counter <- safety_counter + 1;
                                if (safety_counter >= max_safety) {
                                    break; // Exit this loop but the agent will try again next cycle
                                }
                            }
                        }
                    } else {
                        // Same random direction logic for when no path exists
                        bool found_valid_move <- false;
                        int safety_counter <- 0;
                        int max_safety <- 100; // Safety measure to prevent CPU hogging
                        
                        loop while: (not found_valid_move) {
                            float random_angle <- rnd(360.0);
                            point possible_move <- self.location + {cos(random_angle) * speed * 1.2, sin(random_angle) * speed * 1.2};
                            
                            if ((cell_grid closest_to possible_move).is_land) {
                                location <- possible_move;
                                found_valid_move <- true;
                            }
                            
                            // Safety exit - prevents infinite loops but allows agent to try again next cycle
                            safety_counter <- safety_counter + 1;
                            if (safety_counter >= max_safety) {
                                break; // Exit this loop but the agent will try again next cycle
                            }
                        }
                    }
                } else {
                    // Random wandering when no tourists
                    bool found_valid_move <- false;
                    int safety_counter <- 0;
                    int max_safety <- 100; // Safety measure to prevent CPU hogging
                    
                    loop while: (not found_valid_move) {
                        float random_angle <- rnd(360.0);
                        point possible_move <- self.location + {cos(random_angle) * speed * 1.2, sin(random_angle) * speed * 1.2};
                        
                        if ((cell_grid closest_to possible_move).is_land) {
                            location <- possible_move;
                            found_valid_move <- true;
                        }
                        
                        // Safety exit - prevents infinite loops but allows agent to try again next cycle
                        safety_counter <- safety_counter + 1;
                        if (safety_counter >= max_safety) {
                            break; // Exit this loop but the agent will try again next cycle
                        }
                    }
                }
            }
        }
    }
    
    aspect default {
        draw circle(agent_size * 5) color: is_dead ? #red : (is_safe ? #green : color) border: #black;
    }
}

// Car species definition
species car skills: [moving] {
    bool is_dead <- false;
    bool is_safe <- false;
    rgb color <- #brown;
    float speed <- rnd(car_speed_min, car_speed_max);
    int nb_people_in <- 1 + rnd(3);  // 1-4 people in car
    float cars_time_wait <- 0.0;
    
    aspect default {
        draw car_icon size: {150,100} rotate: heading at: location;  // Much larger size
    }
    
    reflex check_safety when: !is_dead and !is_safe {
        shelter nearest_shelter <- shuffle(shelter) first_with (each distance_to self < 10.0);
        if (nearest_shelter != nil) {
            if (nearest_shelter.current_occupants + nb_people_in <= nearest_shelter.capacity) {
                is_safe <- true;
                color <- #green;
                nearest_shelter.current_occupants <- nearest_shelter.current_occupants + nb_people_in;
                location <- nearest_shelter.location;
                cars_safe <- cars_safe + 1;
                cars_in_danger <- cars_in_danger - 1;
            }
        }
    }
    
    reflex move when: !is_dead and !is_safe and (cycle mod update_frequency = 0) {
        // Strategy 1: Always go ahead
        if (car_strategy = "always go ahead") {
            shelter target_shelter <- shuffle(shelter) with_min_of (each distance_to self);
            path path_to_target <- topology(road) path_between (self.location, target_shelter.location);
            
            if (path_to_target != nil and !empty(path_to_target.vertices)) {
                // Check if next point is on land (ocean avoidance)
                point next_point <- first(path_to_target.vertices);
                
                if ((cell_grid closest_to next_point).is_land) {
                    // Check for agents blocking the way
                    list<people> people_ahead <- people at_distance 5.0;
                    list<car> cars_ahead <- car at_distance 5.0;
                    
                    if (!empty(people_ahead) or !empty(cars_ahead)) {
                        // Path is blocked, wait in place
                        // Could add a waiting animation or state indicator here
                    } else {
                        // Path is clear, adjust speed and move
                        // Speed up if no car ahead
                        speed <- speed + car_acceleration;
                        // Clamp speed
                        speed <- min([max([speed, car_speed_min]), car_speed_max]);
                        do follow path: path_to_target speed: speed;
                    }
                } else {
                    // Next point is in ocean, find random land movement
                    int safety_counter <- 0;
                    int max_safety <- 100; // Safety measure to prevent CPU hogging
                    bool found_valid_move <- false;
                    
                    loop while: (not found_valid_move) {
                        float random_angle <- rnd(360.0);
                        point possible_move <- self.location + {cos(random_angle) * speed, sin(random_angle) * speed};
                        
                        if ((cell_grid closest_to possible_move).is_land) {
                            location <- possible_move;
                            found_valid_move <- true;
                        }
                        
                        // Safety exit - prevents infinite loops but allows agent to try again next cycle
                        safety_counter <- safety_counter + 1;
                        if (safety_counter >= max_safety) {
                            break; // Exit this loop but the agent will try again next cycle
                        }
                    }
                }
            }
        }
        // Strategy: Go out when congestion
        else if (car_strategy = "go out when congestion") {
            shelter target_shelter <- shuffle(shelter) with_min_of (each distance_to self);
            path path_to_target <- topology(road) path_between (self.location, target_shelter.location);
            
            if (path_to_target != nil and !empty(path_to_target.vertices)) {
                // Check if next point is on land
                point next_point <- first(path_to_target.vertices);
                
                if ((cell_grid closest_to next_point).is_land) {
                    // Check for people or cars ahead
                    list<people> people_ahead <- people at_distance 5.0;
                    list<car> cars_ahead <- car at_distance 5.0;
                    
                    if (!empty(people_ahead) or !empty(cars_ahead)) {
                        // There are agents blocking the way
                        cars_time_wait <- cars_time_wait + 1;
                        
                        if (cars_time_wait >= cars_threshold_wait) {
                            // Create people from car occupants
                            create people number: nb_people_in {
                                type <- "local";
                                location <- myself.location;
                                color <- #yellow;
                                is_dead <- false;
                                is_safe <- false;
                                speed <- rnd(human_speed_min, human_speed_max);
                            }
                            cars_in_danger <- cars_in_danger - 1;
                            do die;
                        }
                    } else {
                        // Path is clear
                        cars_time_wait <- 0;
                        speed <- speed + car_acceleration;
                        speed <- min([max([speed, car_speed_min]), car_speed_max]);
                        do follow path: path_to_target speed: speed;
                    }
                } else {
                    // Next point is in ocean, use random land movement
                    int safety_counter <- 0;
                    int max_safety <- 100; // Safety measure to prevent CPU hogging
                    bool found_valid_move <- false;
                    
                    loop while: (not found_valid_move) {
                        float random_angle <- rnd(360.0);
                        point possible_move <- self.location + {cos(random_angle) * speed, sin(random_angle) * speed};
                        
                        if ((cell_grid closest_to possible_move).is_land) {
                            location <- possible_move;
                            found_valid_move <- true;
                        }
                        
                        // Safety exit - prevents infinite loops but allows agent to try again next cycle
                        safety_counter <- safety_counter + 1;
                        if (safety_counter >= max_safety) {
                            break; // Exit this loop but the agent will try again next cycle
                        }
                    }
                }
            }
        }
    }
}

// Boat species definition
species boat skills: [moving] {
    bool is_dead <- false;
    bool is_safe <- false;
    rgb color <- #blue;
    float speed <- rnd(boat_speed_min, boat_speed_max);
    
    aspect default {
        draw boat_icon size: {200,150} rotate: heading at: location;
    }
}

experiment tsunami_simulation type: gui {
    parameter "Number of locals" var: locals_number min: 0 max: 10000;
    parameter "Number of tourists" var: tourists_number min: 0 max: 5000;
    parameter "Number of rescuers" var: rescuers_number min: 0 max: 1000;
    parameter "Tourist Movement Strategy" var: tourist_strategy among: ["wandering", "following rescuers or locals", "following crowd"] init: "following rescuers or locals";
    parameter "Car Movement Strategy" var: car_strategy among:["always go ahead", "go out when congestion"];
    
    output {
        display main_display type: opengl {
            overlay position: { 5, 5 } size: { 180, 20 } background: #black transparency: 0.5 {
                draw "Tsunami Evacuation Model" at: { 10, 15 } color: #white font: font("Arial", 16, #bold);
            }
            
            // Draw background and infrastructure
            species cell_grid aspect: default transparency: 0.3;
            species building aspect: default transparency: 0.7;
            species road aspect: default;
            
            // Draw vehicles and people
            species car aspect: default transparency: 0.0;  // No transparency for vehicles
            species boat aspect: default transparency: 0.0;
            species people aspect: default;
            species shelter aspect: default;
            
            // Draw tsunami on top
            graphics "tsunami" {
                if cycle >= tsunami_approach_time {
                    draw tsunami_shape color: rgb(0,0,255,0.5) border: rgb(0,0,255,0.8);
                }
            }
            
            graphics "Legend" {
                float x <- world.shape.width * 0.8;
                float y <- world.shape.height * 0.95;
                
//                draw "Shelter" at: {x, y} color: #black font: font("Arial", 14, #bold);
//                draw circle(10) at: {x + 50, y} color: rgb(0, 255, 0, 0.6) border: #black;
                
                // Population counts
//                draw "Locals: " + length(people where (each.type = "local")) at: {x, y - 30} color: #black;
//                draw "Tourists: " + length(people where (each.type = "tourist")) at: {x, y - 50} color: #black;
//                draw "Rescuers: " + length(people where (each.type = "rescuer")) at: {x, y - 70} color: #black;
//                draw "Cars: " + length(car) at: {x, y - 90} color: #black;
//                draw "Boats: " + length(boat) at: {x, y - 110} color: #black;
            }
        }
        
        monitor "Safe locals" value: locals_safe;
        monitor "Dead locals" value: locals_dead;
        monitor "Safe tourists" value: tourists_safe;
        monitor "Dead tourists" value: tourists_dead;
        monitor "Safe rescuers" value: rescuers_safe;
        monitor "Dead rescuers" value: rescuers_dead;
        monitor "Safe cars" value: cars_safe;
        monitor "Dead cars" value: cars_dead;
        monitor "Safe boats" value: boats_safe;
        monitor "Dead boats" value: boats_dead;
        // Add separate charts for safe and dead agents
        display "Safe Agents Chart" {
            chart "Safe Agents Status" type: series {
                // Safe agents data
                data "Safe Locals" value: locals_safe color: rgb(255, 191, 0);
                data "Safe Tourists" value: tourists_safe color: #violet;
                data "Safe Rescuers" value: rescuers_safe color: #blue;
            }
        }
        
        display "Dead Agents Chart" {
            chart "Dead Agents Status" type: series {
                // Dead agents data
                data "Dead Locals" value: locals_dead color: rgb(255, 191, 0);
                data "Dead Tourists" value: tourists_dead color: #violet;
                data "Dead Rescuers" value: rescuers_dead color: #blue;
            }
        }
        
        // Keep the overall pie chart
        display "Overall Safety Status" {
            chart "Overall Safety vs Casualties" type: pie {
                data "Total Safe" value: locals_safe + tourists_safe + rescuers_safe color: #green;
                data "Total Casualties" value: locals_dead + tourists_dead + rescuers_dead color: #red;
            }
        }
    }
}