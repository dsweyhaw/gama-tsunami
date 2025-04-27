model tsunami

global {
    // GIS and data files
    file building_shapefile <- file("../includes/buildings.shp");
    file road_shapefile <- file("../includes/roads.shp");
    file shelter_csvfile <- csv_file("../includes/shelters.csv", ",");
    
    // Environment parameters
    geometry shape <- envelope(building_shapefile);
    
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
    float locals_size <- 2.0;
    
    int tourists_number <- 50;
    float tourists_size <- 2.0;
    
    int rescuers_number <- 20;
    float rescuers_size <- 2.0;
    
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
    
    init {
        // Create physical environment
        create building from: building_shapefile;
        create road from: road_shapefile;
        
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
        draw shape color: is_flooded ? #blue : #black width: 2.0;
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
    
    // Death checking reflex - runs every step
    reflex check_death when: !is_dead and !is_safe {
        // Check if current location is flooded
        if (road closest_to self).is_flooded {
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
                // Locals head directly to nearest shelter
                do goto target: shelter closest_to self speed: speed;
            }
            match "tourist" {
                // Tourists follow their strategy (wandering/following/crowd)
                if (tourist_strategy = "wandering") {
                    do wander amplitude: 120.0 speed: speed;
                } else if (tourist_strategy = "following rescuers or locals") {
                    if (leader = nil) {
                        // Look for a leader (rescuer first, then local)
                        list<people> potential_leaders <- (people where (each.type = "rescuer")) at_distance radius_look;
                        if (empty(potential_leaders)) {
                            potential_leaders <- (people where (each.type = "local")) at_distance radius_look;
                        }
                        if (!empty(potential_leaders)) {
                            leader <- potential_leaders[0];
                        }
                    }
                    if (leader != nil) {
                        do goto target: leader speed: speed;
                    } else {
                        do wander amplitude: 120.0 speed: speed;
                    }
                }
            }
            match "rescuer" {
                // Rescuers look for tourists then head to shelter
                list<people> nearby_tourists <- (people where (each.type = "tourist" and !each.is_safe)) at_distance radius_look;
                if (!empty(nearby_tourists)) {
                    do goto target: shelter closest_to self speed: speed;
                } else {
                    do wander amplitude: 120.0 speed: speed * 1.2;
                }
            }
        }
    }
    
    aspect default {
        draw circle(agent_size * 5) color: is_dead ? #red : (is_safe ? #green : color) border: #black;
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
            
            species building aspect: default transparency: 0.7;
            species road aspect: default;
            species shelter aspect: default;
            species people aspect: default;
            
            graphics "Legend" {
                float x <- world.shape.width * 0.8;
                float y <- world.shape.height * 0.95;
                
                draw "Shelter" at: {x, y} color: #black font: font("Arial", 14, #bold);
                draw circle(10) at: {x + 50, y} color: rgb(0, 255, 0, 0.6) border: #black;
                
                // Population counts
                draw "Locals: " + length(people where (each.type = "local")) at: {x, y - 30} color: #black;
                draw "Tourists: " + length(people where (each.type = "tourist")) at: {x, y - 50} color: #black;
                draw "Rescuers: " + length(people where (each.type = "rescuer")) at: {x, y - 70} color: #black;
            }
        }
        
        monitor "Safe locals" value: locals_safe;
        monitor "Dead locals" value: locals_dead;
        monitor "Safe tourists" value: tourists_safe;
        monitor "Dead tourists" value: tourists_dead;
        monitor "Safe rescuers" value: rescuers_safe;
        monitor "Dead rescuers" value: rescuers_dead;
    }
}