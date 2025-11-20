using Baumkuchen, Term


# Alternatively: Baumkuchen.@progress :term for i in 1:10
Baumkuchen.BACKEND[] = :term
Baumkuchen.@progress for i in 1:10
    J = rand(1:100)
    # This will disappear after this (outer) loop finishes and will be overwritten in each outer iteration
    Baumkuchen.update_progress!(__progress__; outer_J_transient=J, transient=true)
    # This will stay after this (outer) loop finishes and will be overwritten in each outer iteration
    Baumkuchen.update_progress!(__progress__; outer_J_nontransient=J, transient=false)
    for j in 1:J
        # This will disappear after this (inner) loop finishes
        Baumkuchen.update_progress!(__progress__; inner_J_transient=J, transient=true)
        # This will stay after this (inner) loop finishes and a new line will be generated for every outer iteration 
        Baumkuchen.update_progress!(__progress__; inner_J_nontransient=J, transient=false)
        sleep(.001)
    end 
    # Baumkuchen.finalize_progress!(tmp)
end