model tsunami

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
    float human_speed_avg <- 1.4;  
    float human_speed_min <- 0.8;
    float human_speed_max <- 3.0;
    
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
    string tourist_strategy <- "wandering" among: ["wandering", "following rescuers or locals", "following crowd"];
    
    // Tsunami parameters
    float tsunami_speed <- 44.3;  // m/s
    int tsunami_approach_time <- 460; // seconds
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
    float car_speed_min <- 1.4;  // m/s
    float car_speed_max <- 36.1; // m/s
    float car_acceleration <- 5.0;
    float car_deceleration <- 5.0;
    int cars_threshold_wait <- 5;
    string car_strategy <- "always go ahead" among: ["always go ahead", "go out when congestion"];  // Removed unused strategy

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

    init {
        // Create physical environment first
        create building from: building_shapefile {
            shape <- shape + 0.5; // Add small buffer to buildings
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
        return (valid_area covers new_loc) and (shape intersects land_area);
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
    reflex move when: !is_dead and !is_safe {
        switch type {
            match "local" {
                point target <- (shelter closest_to self).location;
                path path_to_target <- topology(road) path_between (self.location, target);
                if (path_to_target != nil) {
                    do follow path: path_to_target speed: speed;
                }
            }
            match "tourist" {
                // Tourists follow their strategy (wandering/following/crowd)
                if (tourist_strategy = "wandering") {
                    point possible_loc <- self.location + {rnd(-1,1) * speed, rnd(-1,1) * speed};
                    if (is_valid_location(possible_loc)) {
                        location <- possible_loc;
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
                }
            }
            match "rescuer" {
                // Rescuers look for tourists then head to shelter
                list<people> nearby_tourists <- (people where (each.type = "tourist" and !each.is_safe)) at_distance radius_look;
                if (!empty(nearby_tourists)) {
                    point target <- (shelter closest_to self).location;
                    path path_to_target <- topology(road) path_between (self.location, target);
                    if (path_to_target != nil) {
                        do follow path: path_to_target speed: speed;
                    }
                } else {
                    point possible_loc <- self.location + {rnd(-1,1) * speed * 1.2, rnd(-1,1) * speed * 1.2};
                    if (is_valid_location(possible_loc)) {
                        location <- possible_loc;
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

    reflex move when: !is_dead and !is_safe {
        // Strategy 1: Always go ahead
        if (car_strategy = "always go ahead") {
            shelter target_shelter <- shuffle(shelter) with_min_of (each distance_to self);
            path path_to_target <- topology(road) path_between (self.location, target_shelter.location);
            if (path_to_target != nil) {
                // Check for car ahead
                list<car> nearby_cars <- car at_distance 10.0;
                car car_ahead <- !empty(nearby_cars) ? nearby_cars first_with (each.location = location + {cos(heading), sin(heading)} * 10.0) : nil;

                if (car_ahead != nil) {
                    // Slow down
                    speed <- speed - car_deceleration;
                } else {
                    // Speed up
                    speed <- speed + car_acceleration;
                }
                // Clamp speed
                speed <- min([max([speed, car_speed_min]), car_speed_max]);
                do follow path: path_to_target speed: speed;
            }
        }
        // Strategy 3: Go out when congestion
        else if (car_strategy = "go out when congestion") {
            shelter target_shelter <- shuffle(shelter) with_min_of (each distance_to self);
            path path_to_target <- topology(road) path_between (self.location, target_shelter.location);
            if (path_to_target != nil) {
                list<car> nearby_cars <- car at_distance 10.0;
                if (!empty(nearby_cars)) {
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
                    cars_time_wait <- 0;
                    speed <- speed + car_acceleration;
                    speed <- min([max([speed, car_speed_min]), car_speed_max]);
                    do follow path: path_to_target speed: speed;
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
    parameter "Number of locals" var: locals_number min: 0 max: 1000;
    parameter "Number of tourists" var: tourists_number min: 0 max: 500;
    parameter "Number of rescuers" var: rescuers_number min: 0 max: 100;
    
    output {
        display main_display type: opengl {
            overlay position: { 5, 5 } size: { 180, 20 } background: #black transparency: 0.5 {
                draw "Tsunami Evacuation Model" at: { 10, 15 } color: #white font: font("Arial", 16, #bold);
            }
            
            // Draw background and infrastructure
            species cell_grid aspect: default transparency: 0.3;
            species building aspect: default transparency: 0.7;
            species road aspect: default;
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
                
                draw "Shelter" at: {x, y} color: #black font: font("Arial", 14, #bold);
                draw circle(10) at: {x + 50, y} color: rgb(0, 255, 0, 0.6) border: #black;
                
                // Population counts
                draw "Locals: " + length(people where (each.type = "local")) at: {x, y - 30} color: #black;
                draw "Tourists: " + length(people where (each.type = "tourist")) at: {x, y - 50} color: #black;
                draw "Rescuers: " + length(people where (each.type = "rescuer")) at: {x, y - 70} color: #black;
                draw "Cars: " + length(car) at: {x, y - 90} color: #black;
                draw "Boats: " + length(boat) at: {x, y - 110} color: #black;
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
    }
}