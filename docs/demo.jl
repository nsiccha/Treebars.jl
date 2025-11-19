using Baumkuchen, Term

Baumkuchen.@progress :term for i in 1:100
    println(i)
    sleep(.0001)
end