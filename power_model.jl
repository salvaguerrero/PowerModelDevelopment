using Dates
using JSON
using StructTypes
using DataFrames
using CSV
using Statistics
#using Plots
using PlotlyJS

using JuMP
using OSQP
using Gurobi

using AWS, AWSS3

global CLOUD = false

#Struct definition
###############################################

mutable struct PowerModel
    name::String
    start_date::DateTime
    end_date::DateTime
    res::Int    
    stc::Bool
    csv::Union{String,Vector{SubString{String}}}           
end

mutable struct Generator
    name::String
    fuel_id::Union{Int, Vector{Int}}
    fuel_curve::Union{Float64, Vector{Float64}, Matrix{Float64}} 
    node_id::Int
    technology::String
    must_run::Union{Float64, Vector{Float64}} 
    capacity::Union{Float64, Vector{Float64}}
    capacity_dev::Union{Float64, Vector{Float64}}  #standard deviation
    rump_up::Float64
    rump_down::Float64
    uc::Bool
    complex::Bool
end

mutable struct HydroPower
    name::String
    node_id::Int
    must_run::Union{Float64, Vector{Float64}} 
    pump_cap::Union{Float64, Vector{Float64}}
    gen_cap::Union{Float64, Vector{Float64}}
    res_cap::Union{Float64, Vector{Float64}}
    inflows::Union{Float64, Vector{Float64}}
    outflows::Union{Float64, Vector{Float64}}
    gen_eff::Float64
    pum_eff::Float64
    rump_up::Float64
    rump_down::Float64
end

mutable struct Line
    name::String
    from_id::Int          
    to_id::Int
    from_to_cap::Union{Float64, Vector{Float64}} 
    to_from_cap::Union{Float64, Vector{Float64}} 
end

mutable struct Node
    name::String
    generators_id::Union{Int, Vector{Int}} 
    batteries_id::Union{Int, Vector{Int}}           
    from_lines_id::Union{Int, Vector{Int}}   
    to_lines_id::Union{Int, Vector{Int}}   
    hydropower_id::Union{Int, Vector{Int}}   
    demand::Union{Float64, Vector{Float64}} 
    demand_dev::Union{Float64, Vector{Float64}}  #standard deviation
    ens_cost::Float32
    mrkt_prc::Union{Float64, Vector{Float64}} 
    buy_cap::Union{Float64, Vector{Float64}}
    sell_cap::Union{Float64, Vector{Float64}} 
end

mutable struct Battery
    name::String
    node_id::Int
    cha_cap::Union{Float64, Vector{Float64}} 
    dis_cap::Union{Float64, Vector{Float64}}
    ene_cap::Union{Float64, Vector{Float64}}  
    ene_i::Float64
    ene_f::Float64
end

mutable struct Fuel
    name::String
    cost::Union{Float64, Vector{Float64}} 
    cost_dev::Union{Float64, Vector{Float64}}   #standard deviation
end

mutable struct Hydro
    name::String
    node_id::Int
    gen_cap::Union{Float64, Vector{Float64}}  
    pmp_cap::Union{Float64, Vector{Float64}}  
    must_run::Union{Float64, Vector{Float64}}  
    inflows::Union{Float64, Vector{Float64}} 
    rsv_cap::Float64 
    ene_i::Float64
    ene_f::Float64
    tur_eff::Float64
    pmp_eff::Float64
end

mutable struct PowerModelData
    TimeRange::StepRange{DateTime, Hour}
    Range::UnitRange{Int64}
    T::Int
    GenNum::Int
    Gen::Vector{Generator}
    LinNum::Int
    Lin::Vector{Line}
    NodNum::Int
    Nod::Vector{Node}
    BatNum::Int
    Bat::Vector{Battery}
    FueNum::Int
    Fue::Vector{Fuel}
    HydNum::Int
    Hyd::Vector{Hydro}
end


#Struct parsers
###############################################
function read_json(file::String)
    if CLOUD
        bucket = "sgg-test-julia"
        key    = file
        local_file = "/tmp/"*file  
        s3_get_file(aws, bucket, key, local_file)
    else 
        local_file = file  
    end
    open(local_file,"r") do f
        return JSON.parse(f)
    end
end
function read_csv(csv_files::Vector{SubString{String}})::Dict{String, DataFrame}
    df_s = Dict{String, DataFrame}()
    for csv in csv_files
        csv = ( !(occursin(".csv",csv)) ? csv*".csv" : csv) 
        if CLOUD
            bucket = "sgg-test-julia"
            key    = csv
            local_file = "/tmp/"*csv  
            s3_get_file(aws, bucket, key, local_file)
        else 
            local_file = csv  
        end
        csv = split(csv, ".")[1]
        csv = split(csv, "/")[end]
        df_s[csv] = CSV.read(local_file, DataFrame)
    end
    return df_s
end
function dict_to_powermodel(data::Dict)::PowerModel

    name = first(keys(data))
    data = data[name]
    CSVs  = split(data["CSV"], ",")
    for (f,file) in enumerate(CSVs)
        if file[1] == ' '
            file = file[2:end]
        end
        if file[end] == ' '
            file = file[1:end-1]
        end
        CSVs[f] = file
    end
    return PowerModel(  
        name,
        DateTime(data["start_date"], DateFormat("dd/mm/yyyy HH:MM")),
        DateTime(data["end_date"],   DateFormat("dd/mm/yyyy HH:MM")),
        Int.(eval(Meta.parse(data["resolution"]))),
        parse(Bool,lowercase(data["stochastic"])),
        CSVs
    )
end
function dict_to_generator(data::Dict,df_s::Dict{String, DataFrame})::Generator

    df_keys = keys(df_s)

    i = split(data["must_run"], "-")
    must_run = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["capacity"], "-")
    capacity = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["dev_capacity"], "-")
    dev_capacity = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 


    return Generator(
        data["name"],
        Int.(eval(Meta.parse(data["fuel_id"]))),
        float(eval(Meta.parse(data["fuel_curve"]))), 
        Int.(parse(Int, data["node_id"])),
        data["tech"],
        float(must_run),
        float(capacity),
        float(dev_capacity),
        float(eval(Meta.parse(data["ramp_up"]))),
        float(eval(Meta.parse(data["ramp_down"]))),
        eval(Meta.parse(lowercase(data["UC"]))),        
        eval(Meta.parse(lowercase(data["complex"])))
    )
end
function dict_to_battery(data::Dict,df_s::Dict{String, DataFrame})::Battery


    df_keys = keys(df_s)

    i = split(data["charge_cap"], "-")
    cha_cap = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["discharge_cap"], "-")
    dis_cap = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["enegy_cap"], "-")
    ene_cap = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 

    return Battery(
        data["name"],
        Int.(parse(Int, data["node_id"])),
        float(cha_cap),
        float(dis_cap),
        float(ene_cap),
        float(eval(Meta.parse(data["ene_i"]))),
        float(eval(Meta.parse(data["ene_f"])))
    )
end
function dict_to_line(data::Dict,df_s::Dict{String, DataFrame})::Line

    df_keys = keys(df_s)

    i = split(data["from_to_cap"], "-")
    from_to_cap = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["to_from_cap"], "-")
    to_from_cap = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 

    return Line(
        data["name"],
        Int.(eval(Meta.parse(data["from_id"]))),
        Int.(eval(Meta.parse(data["to_id"]))),        
        float(from_to_cap),
        float(to_from_cap)
    )
end
function dict_to_fuel(data::Dict,df_s::Dict{String, DataFrame})::Fuel

    df_keys = keys(df_s)

    i = split(data["cost"], "-")
    cost = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["dev_cost"], "-") 
    dev_cost = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 


    return Fuel(
        data["name"],
        float(cost),
        float(dev_cost)
    )
end
function dict_to_node(data::Dict, id_list::Dict{String, Vector{Int64}}, df_s::Dict{String, DataFrame})::Node

    df_keys = keys(df_s)

    i = split(data["demand"], "-")
    demand = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["dev_demand"], "-") 
    dev_demand = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 

    i = split(data["mrkt_prc"], "-") 
    mrkt_prc = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["mrkt_buy_cap"], "-") 
    mrkt_buy_cap = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["mrkt_sell_cap"], "-") 
    mrkt_sell_cap = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 

    return Node(
        data["name"],
        id_list["generators"], 
        id_list["batteries"],
        id_list["from_lines"],
        id_list["to_lines"],
        id_list["hydropower"],
        float(demand),
        float(dev_demand),
        float(eval(Meta.parse(data["ens_cost"]))),
        float(mrkt_prc),
        float(mrkt_buy_cap),
        float(mrkt_sell_cap)
    )
end
function dict_to_hydropower(data::Dict,df_s::Dict{String, DataFrame})::Hydro

    df_keys = keys(df_s)

    i = split(data["must_run"], "-")
    must_run = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["pump_cap"], "-")
    pump_cap = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["gen_cap"], "-")
    gen_cap = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 
    i = split(data["inflows"], "-")
    inflows = (i[1] in df_keys ? df_s[ i[1] ][!, i[2] ] : eval(Meta.parse(i[1] )) ) 

    return Hydro(
        data["name"],
        Int.(eval(Meta.parse(data["node_id"]))),
        float(gen_cap),
        float(pump_cap),
        float(must_run),
        float(inflows),
        float(eval(Meta.parse(data["reservor_cap"]))),
        float(eval(Meta.parse(data["ene_i"]))),
        float(eval(Meta.parse(data["ene_f"]))),
        float(eval(Meta.parse(data["turb_eff"]))),
        float(eval(Meta.parse(data["pump_eff"])))
    )
end

#--------------------------------------------------------------------------
#------------------------------ Model Execution ---------------------------
#--------------------------------------------------------------------------

#------------------------------ Data Loader  ------------------------------

if CLOUD 
    aws_access_key_id = get(ENV,"AWS_ACCESS_KEY_ID","")
    aws_secret_access_key = get(ENV, "AWS_SECRET_ACCESS_KEY","")
    aws_region = get(ENV,"AWS_DEFAULT_REGION","eu-north-1")

    global aws = global_aws_config(;#creds = AWS.AWSCredentials(aws_access_key_id, aws_secret_access_key),
        region= aws_region) # pass keyword arguments to change defaults
end


file = "model.json"
file = "european model/Dummy Model/europe_model.json"
file = "european model/europe_test.json"
data_json = read_json(file)

model_conf = dict_to_powermodel(data_json["execution"])
TimeRange = range(model_conf.start_date, stop=model_conf.end_date, step=Hour(model_conf.res))
T = length(TimeRange)
Range     = 1:T

df_s = read_csv(model_conf.csv)

for df_name in keys(df_s)
    df_s[df_name].time = DateTime.(df_s[df_name].time, "dd/mm/yyyy HH:MM")
    df_s[df_name] = df_s[df_name][(df_s[df_name].time .>= model_conf.start_date) .& (df_s[df_name].time .<= model_conf.end_date), :]
end

NodNum = length(data_json["nodes"])
base_id_dict = Dict(
    "generators" => [0],
    "from_lines" => [0],
    "to_lines"   => [0],
    "batteries"  => [0],
    "hydropower" => [0]
    )
id_list = Vector{Dict}(undef, NodNum) 
for n in 1:NodNum
    id_list[n] = copy(base_id_dict)
end


GenNum = length(data_json["generators"])
generators = Vector{Generator}(undef, GenNum) 
i = 1
for g in 1:GenNum
    data = data_json["generators"][string(g)]
    generators[i] = dict_to_generator(data, df_s)
    node_id = generators[i].node_id 
    if id_list[node_id]["generators"] == [0]
        id_list[node_id]["generators"] = [g]
    else
        push!(id_list[node_id]["generators"], g)  
    end
    i+=1
end

LinNum = length(data_json["lines"])
lines = Vector{Line}(undef, LinNum)
i = 1
for l in 1:LinNum
    data = data_json["lines"][string(l)]
    lines[i] = dict_to_line(data,df_s)
    
    node_id = lines[i].from_id 
    if id_list[node_id]["from_lines"] == [0]
        id_list[node_id]["from_lines"] = [l]
    else
        push!(id_list[node_id]["from_lines"], l)  
    end
    
    node_id = lines[i].to_id 
    if id_list[node_id]["to_lines"] == [0]
        id_list[node_id]["to_lines"] = [l]
    else
        push!(id_list[node_id]["to_lines"], l)  
    end

    i+=1
end

FueNum = length(data_json["fuels"])
fuels = Vector{Fuel}(undef, FueNum) 
i = 1
for f in 1:FueNum
    data = data_json["fuels"][string(f)]
    fuels[i] = dict_to_fuel(data,df_s)
    i+=1
end

BatNum = length(data_json["batteries"])
batteries = Vector{Battery}(undef, BatNum) 
i = 1
for b in 1:BatNum
    data = data_json["batteries"][string(b)]
    batteries[i] = dict_to_battery(data,df_s)
    node_id = batteries[i].node_id 
    if id_list[node_id]["batteries"] == [0]
        id_list[node_id]["batteries"] = [b]
    else
        push!(id_list[node_id]["batteries"], b)  
    end
    i+=1
end

HydNum = length(data_json["hydropower"])
hydro  = Vector{Hydro}(undef, HydNum) 
i = 1
for h in 1:HydNum
    data = data_json["hydropower"][string(h)]
    hydro[i] = dict_to_hydropower(data,df_s)
    node_id = hydro[i].node_id 
    if id_list[node_id]["hydropower"] == [0]
        id_list[node_id]["hydropower"] = [h]
    else
        push!(id_list[node_id]["hydropower"], h)  
    end   
    i+=1
end

NodNum = length(data_json["nodes"])
nodes = Vector{Node}(undef, NodNum) 
i = 1
for n in 1:NodNum
    data = data_json["nodes"][string(n)]
    nodes[i] = dict_to_node(data,id_list[n],df_s)
    i+=1
end

m = PowerModelData( 
    TimeRange,Range,T,
    GenNum,generators,
    LinNum,lines,
    NodNum,nodes,
    BatNum,batteries,
    FueNum,fuels,
    HydNum,hydro
    )

function get_at_t(TimeRange::StepRange{DateTime, Hour}, vec::Union{Float64, Vector{Float64}}, t::Int)::Float64

    if length(vec) == 1     #vec is a scalar not a vector
        return vec
    elseif length(vec) == 0 #vec is empty/null etc
        return 0           
    end 

    #Identify the vector granularity and adjust index:
    if length(vec) == length(TimeRange)
        index = t

    elseif length(vec) == ( (year(TimeRange[end]) - year(TimeRange[1])) + 1) #Yearly vec
        index = t_to_y(t,TimeRange)

    elseif length(vec) == ( month(TimeRange[end]) - month(TimeRange[1]) + (year(TimeRange[end]) - year(TimeRange[1])) * 12 + 1) #Monthly vec
        index = t_to_m(t,TimeRange)

    elseif length(vec) == ceil( length(TimeRange)*step(TimeRange).value /24/7 ) #Weekly vec
        index = t_to_w(t,TimeRange)

    elseif length(vec) == ceil( length(TimeRange)*step(TimeRange).value /24 ) #Daily vec
        index = t_to_d(t,TimeRange)
    else
        throw("get_at_t error: vector granularity not found")
    end

    if length(vec) >= index
        return vec[index]
    else
        throw("get_at_t error: vector length is less then $t")
    end 
end   

@inline function t_to_d(t::Int,TimeRange::StepRange{DateTime, Hour})::Int 
    return ceil( t*step(TimeRange).value /24 )
end
@inline function t_to_w(t::Int,TimeRange::StepRange{DateTime, Hour})::Int 
    return ceil( t*step(TimeRange).value /24/7 )
end
@inline function t_to_m(t::Int,TimeRange::StepRange{DateTime, Hour})::Int 
    month_diff = month(TimeRange[t]) - month(TimeRange[1]) + (year(TimeRange[t]) - year(TimeRange[1])) * 12 + 1
    return month_diff
end
@inline function t_to_y(t::Int,TimeRange::StepRange{DateTime, Hour})::Int 
    return (year(TimeRange[t]) - year(TimeRange[1])) + 1
end


#------------------------------ Optimization Model  ------------------------------


init = now()
println("Building model time")

#model = Model(OSQP.Optimizer; add_bridges = false)
model = Model(Gurobi.Optimizer; add_bridges = false)
set_string_names_on_creation(model, false)

#------------------------------ Variables ------------------------------
#Generator
@variable(model,       g_gen[t in m.Range, g in 1:m.GenNum] >= 0 ) #Generator power output [MW]
@variable(model,  0 <=  g_uc[t in m.Range, g in 1:m.GenNum; m.Gen[g].uc] <= 1 ) #Unit commintment 

#Hydro
@variable(model, h_res[t in m.Range, h in 1:m.HydNum] >= 0 ) #Reservoir level [GWh]
@variable(model, h_pmp[t in m.Range, h in 1:m.HydNum] >= 0 ) #Pumped power [MW]
@variable(model, h_tur[t in m.Range, h in 1:m.HydNum] >= 0 ) #Turbined power [MW]
@variable(model, h_spi[t in m.Range, h in 1:m.HydNum] >= 0 ) #Spillage [MW]

#Battery
@variable(model, b_cha[t in m.Range, b in 1:m.BatNum] >= 0 ) #Charge [MW]
@variable(model, b_dis[t in m.Range, b in 1:m.BatNum] >= 0 ) #Discharge[MW]
@variable(model, b_ene[t in m.Range, b in 1:m.BatNum] >= 0 ) #Energy stored at the end of t [MWh]

#Node
@variable(model, n_slc[t in m.Range, n in 1:m.NodNum] >= 0 ) #Node demand slack [MW]
@variable(model, n_buy[t in m.Range, n in 1:m.NodNum] >= 0 ) #Node market buy [MW]
@variable(model,n_sell[t in m.Range, n in 1:m.NodNum] >= 0 ) #Node market sell [MW]


#Lines
@variable(model, l_flo[t in m.Range, l in 1:LinNum]) #Line flow [MW]


#------------------------------ Objective Function ------------------------------
#min cost
obj = @objective(model, Min,    step(m.TimeRange).value*(  
                                    sum(    n_slc[t,n]      * m.Nod[n].ens_cost for n in 1:m.NodNum, t in m.Range ) +
                                    sum(    n_buy[t,n]      * get_at_t(m.TimeRange,m.Nod[n].mrkt_prc,t) for n in 1:m.NodNum, t in m.Range ) +
                                    sum(-1*n_sell[t,n]      * get_at_t(m.TimeRange,m.Nod[n].mrkt_prc,t) for n in 1:m.NodNum, t in m.Range ) +
                                    sum(   (g_gen[t,g]^2)   * m.Gen[g].fuel_curve[ff,1]*get_at_t(m.TimeRange,m.Fue[f].cost,t) +
                                            g_gen[t,g]      * m.Gen[g].fuel_curve[ff,2]*get_at_t(m.TimeRange,m.Fue[f].cost,t) +
                              (m.Gen[g].uc ? g_uc[t,g] : 1) * m.Gen[g].fuel_curve[ff,3]*get_at_t(m.TimeRange,m.Fue[f].cost,t) for g = 1:m.GenNum, t in m.Range, (ff,f) in enumerate(m.Gen[g].fuel_id) if f != 0)
                        )
                        )

#------------------------------ Constraints ------------------------------
#Nodes
@constraint(model, load_balance[t in m.Range, n in 1:m.NodNum], sum(g_gen[t,g] for g in m.Nod[n].generators_id if g != 0) +
                                                                sum(b_dis[t,b] for b in m.Nod[n].batteries_id  if b != 0) +
                                                                sum(l_flo[t,l] for l in m.Nod[n].to_lines_id   if l != 0) + 
                                                                sum(h_tur[t,h] for h in m.Nod[n].hydropower_id if h != 0) +
                                                                    n_slc[t,n]                                            +
                                                                    n_buy[t,n]                                                
                                                                                                                          ==
                                                                    n_sell[t,n]                                           +                                                                              
                                                                sum(h_pmp[t,h] for h in m.Nod[n].hydropower_id if h != 0) +
                                                                sum(b_cha[t,b] for b in m.Nod[n].batteries_id  if b != 0) +
                                                                sum(l_flo[t,l] for l in m.Nod[n].from_lines_id if l != 0) +
                                                                get_at_t(m.TimeRange,m.Nod[n].demand,t)/step(m.TimeRange).value )

@constraint(model,  node_market_buy[t in m.Range, n in 1:m.NodNum], n_buy[t,n] <= get_at_t(m.TimeRange,m.Nod[n].buy_cap,t))
@constraint(model, node_market_sell[t in m.Range, n in 1:m.NodNum],n_sell[t,n] <= get_at_t(m.TimeRange,m.Nod[n].sell_cap,t))
                                                                

#Lines
@constraint(model,  lin_max_cap[t in m.Range, l in 1:m.LinNum], l_flo[t,l] <=    get_at_t(m.TimeRange,m.Lin[l].from_to_cap,t))
@constraint(model,  lin_min_cap[t in m.Range, l in 1:m.LinNum], l_flo[t,l] >= -1*get_at_t(m.TimeRange,m.Lin[l].to_from_cap,t))

#Generators
@constraint(model,  gen_max_cap[t in m.Range, g in 1:m.GenNum], g_gen[t,g] <= get_at_t(m.TimeRange,m.Gen[g].capacity,t)* (m.Gen[g].uc ? g_uc[t,g] : 1) )
@constraint(model, gen_must_run[t in m.Range, g in 1:m.GenNum], g_gen[t,g] >= get_at_t(m.TimeRange,m.Gen[g].must_run,t)* (m.Gen[g].uc ? g_uc[t,g] : 1) )
@constraint(model,    gen_rump_up[t in 2:m.T, g in 1:m.GenNum; t != 1 && m.Gen[g].complex ], (g_gen[t,g] - g_gen[t-1,g]) <= step(m.TimeRange).value*60*m.Gen[g].rump_up  *get_at_t(m.TimeRange,m.Gen[g].capacity,t)    )
@constraint(model,  gen_rump_down[t in 2:m.T, g in 1:m.GenNum; t != 1 && m.Gen[g].complex ], (g_gen[t,g] - g_gen[t-1,g]) >= step(m.TimeRange).value*60*m.Gen[g].rump_down*get_at_t(m.TimeRange,m.Gen[g].capacity,t)    )

#Hydropower
@constraint(model,   hydro_reservoir[t in m.Range, h in 1:m.HydNum], h_res[t,h] == (t > 1 ? h_res[t-1,h] : m.Hyd[h].ene_i) + step(m.TimeRange).value*( h_pmp[t,h]*m.Hyd[h].pmp_eff - h_tur[t,h]/m.Hyd[h].tur_eff - h_spi[t,h])/1000 + get_at_t(m.TimeRange,m.Hyd[h].inflows,t)*step(m.TimeRange).value/24 )
@constraint(model, hydro_max_cap_gen[t in m.Range, h in 1:m.HydNum], h_tur[t,h] <= get_at_t(m.TimeRange,m.Hyd[h].gen_cap,t))
@constraint(model, hydro_max_cap_pmp[t in m.Range, h in 1:m.HydNum], h_pmp[t,h] <= get_at_t(m.TimeRange,m.Hyd[h].pmp_cap,t))
@constraint(model,    hydro_must_run[t in m.Range, h in 1:m.HydNum], h_tur[t,h] >= get_at_t(m.TimeRange,m.Hyd[h].must_run,t))

@constraint(model,hydro_reservoir_f[              h in 1:m.HydNum; m.Hyd[h].ene_f != NaN], h_res[m.T,h] == m.Hyd[h].ene_f )


#Batteries
@constraint(model,  bat_max_cha[t in m.Range, b in 1:m.BatNum], b_cha[t,b] <= get_at_t(m.TimeRange,m.Bat[b].cha_cap,t))
@constraint(model,  bat_max_dis[t in m.Range, b in 1:m.BatNum], b_dis[t,b] <= get_at_t(m.TimeRange,m.Bat[b].dis_cap,t))
@constraint(model,  bat_max_ene[t in m.Range, b in 1:m.BatNum], b_ene[t,b] <= get_at_t(m.TimeRange,m.Bat[b].ene_cap,t))
@constraint(model,    bat_level[t in m.Range, b in 1:m.BatNum], b_ene[t,b] == (t > 1 ? b_ene[t-1,b] : m.Bat[b].ene_i) + (b_cha[t,b] - b_dis[t,b])*step(m.TimeRange).value )
@constraint(model,  bat_level_f[              b in 1:m.BatNum; m.Bat[b].ene_f != NaN], b_ene[m.T,b] == m.Bat[b].ene_f)



build_time = now() - init
println("                            ")
println("Building model time: $build_time")


init = now()
optimize!(model)
opt_time = now() - init
opt_time = round(opt_time.value/1000/60) 
status = termination_status(model)
println("                            ")
println("Optimization time: $opt_time")
println("Optimization Status: $status")

#------------------------------ Solution processing ------------------------------

if status == OPTIMAL::TerminationStatusCode
    println("Dispatch cost: $(objective_value(model))")
    println("Saving Solution")

    init = now()
    node_df = []
    for n in 1:m.NodNum
        df = DataFrame()

        slc = Vector{Float64}(undef, length(m.Range))
        for t in m.Range
            slc[t] = value(n_slc[t, n])
        end
        df[!,  m.Nod[n].name*"_NSE"  ] = slc

        srmc = Vector{Float64}(undef, length(m.Range))
        for t in m.Range
            srmc[t] = dual(load_balance[t,n])
        end
        df[!,  m.Nod[n].name*"_SRMP"  ] = srmc

        for l in m.Nod[n].from_lines_id
            if l != 0
                df[!,  m.Lin[l].name ] = -1*(value.(l_flo[:, l]))
            end
        end

        for l in m.Nod[n].to_lines_id
            if l != 0
                df[!,  m.Lin[l].name ] = value.(l_flo[:, l])
            end
        end

        for h in m.Nod[n].hydropower_id
            if h != 0
                df[!,  m.Hyd[h].name*"_pmp" ] = -1*(value.(h_pmp[:, h]))
                df[!,  m.Hyd[h].name*"_tur" ] =    (value.(h_tur[:, h]))
            end
        end

        for b in m.Nod[n].batteries_id
            if b != 0
                df[!,  m.Bat[b].name*"_char" ] = -1*(value.(b_cha[:, h]))
                df[!,  m.Bat[b].name*"_disc" ] =    (value.(b_dis[:, h]))
            end
        end

        for g in m.Nod[n].generators_id
            if g != 0
                if m.Gen[g].technology in names(df)
                    df[!,m.Gen[g].technology] = df[!,m.Gen[g].technology] + value.(g_gen[:, g])
                else
                    df[!,m.Gen[g].technology] = value.(g_gen[:, g])
                end
            end
        end


        push!(node_df,df)
    end

    hydro_df = []
    for h in 1:m.HydNum
        df = DataFrame()
        df[!,  m.Hyd[h].name*"_Pmp" ] = -1*(value.(h_pmp[:, h]))*m.Hyd[h].pmp_eff * step(m.TimeRange).value / 1000
        df[!,  m.Hyd[h].name*"_Tur" ] =    (value.(h_tur[:, h]))/m.Hyd[h].tur_eff * step(m.TimeRange).value / 1000
        df[!,  m.Hyd[h].name*"_Spi" ] =    (value.(h_spi[:, h]))                  * step(m.TimeRange).value / 1000
        df[!,  m.Hyd[h].name*"_Lev" ] =    (value.(h_res[:, h]))
        push!(hydro_df,df)
    end

    save_time = now() - init
    println("Saving solution time: $save_time")
end

#------------------------------ Solution Plot ------------------------------

if CLOUD == false && status == OPTIMAL::TerminationStatusCode
    #------------------------------ Generation Power Balance ------------------------------    
    plot_list = Array{GenericTrace{Dict{Symbol, Any}}}(undef,0)
    plot_node_id = []
    for n in 1:m.NodNum
        push!(plot_list, scatter(x=TimeRange, y=m.Nod[n].demand/step(m.TimeRange).value, stackgroup=string(n)*"_two", mode="lines", hoverinfo="x+y", fill="none", name=nodes[n].name*"_Demand", line=attr(dash="dash", color="black"), visible=(n==1) ) )
        push!(plot_node_id, n)
        plot_df = node_df[n]
        for col in names(node_df[n])
            if col != m.Nod[n].name*"_SRMP"
                p = scatter(plot_df, x=TimeRange, y=plot_df[!, col], stackgroup=string(n)*"_one", mode="lines", name=col, visible=(n==1))
            else
                p = scatter(plot_df, x=TimeRange, y=plot_df[!, col], stackgroup=string(n)*"_thr", mode="lines",  fill="none", name=col, line=attr(dash="dash", color="blue"), visible=(n==1), yaxis="y2")
            end
            push!(plot_list, p)        
            push!(plot_node_id, n)
        end
    end

    # Generate buttons for the dropdown menu to toggle between plots
    node_buttons = [attr(
        method="update", 
        label="Node: $(m.Nod[n].name)", 
        args=[attr(visible=[(n_id == n) for n_id in plot_node_id])]  # Only the selected plot is visible
    ) for n in 1:m.NodNum]


    plot(plot_list,
    Layout(
        title="Average Power Balance [MW]",
        xaxis=attr(
            rangeslider_visible=true,
            rangeselector=attr(
                buttons=[
                    attr(count=1, label="1d", step="day", stepmode="todate"),
                    attr(count=7, label="1w", step="day", stepmode="backward"),
                    attr(count=1, label="1m", step="month", stepmode="backward"),
                    attr(count=6, label="6m", step="month", stepmode="backward"),
                    attr(step="all")
                ]
            )
        ),
        yaxis2=attr(
            overlaying="y",
            side="right"
        ),        
        updatemenus=[attr(
            buttons=node_buttons
        )]
    ))

    #------------------------------ Hydrologycal Balance ------------------------------    
    plot_list = Array{GenericTrace{Dict{Symbol, Any}}}(undef,0)
    plot_hydro_id = []
    for h in 1:m.HydNum

        plot_df = hydro_df[h]
        for col in names(hydro_df[h])
            if col != m.Hyd[h].name*"_Lev"
                p = scatter(plot_df, x=TimeRange, y=plot_df[!, col], stackgroup=string(h)*"_one", mode="lines", name=col, visible=(h==1))
            else
                p = scatter(plot_df, x=TimeRange, y=plot_df[!, col], stackgroup=string(h)*"_thr", mode="lines",  fill="none", name=col, line=attr(dash="dash", color="blue"), visible=(h==1), yaxis="y2")
                
            end
            push!(plot_list, p)        
            push!(plot_hydro_id, h)
        end

        #Inflows:
        inflows = Vector{Float64}(undef, m.T )
        for t in m.Range
            inflows[t] = get_at_t(m.TimeRange,m.Hyd[h].inflows,t)*step(m.TimeRange).value/24
        end
        push!(plot_list, scatter(x=TimeRange, y=inflows, stackgroup=string(h)*"_one", mode="lines", name=m.Hyd[h].name*"_Inflows", visible=(h==1) ) )
        push!(plot_hydro_id, h)

    end

    # Generate buttons for the dropdown menu to toggle between plots
    node_buttons = [attr(
        method="update", 
        label="Reservoir: $(m.Hyd[h].name)", 
        args=[attr(visible=[(h_id == h) for h_id in plot_hydro_id])]  # Only the selected plot is visible
    ) for h in 1:m.HydNum]


    plot(plot_list,
    Layout(
        title="Average Hydrologycal Balance [GWh]",
        xaxis=attr(
            rangeslider_visible=true,
            rangeselector=attr(
                buttons=[
                    attr(count=1, label="1d", step="day", stepmode="todate"),
                    attr(count=7, label="1w", step="day", stepmode="backward"),
                    attr(count=1, label="1m", step="month", stepmode="backward"),
                    attr(count=6, label="6m", step="month", stepmode="backward"),
                    attr(step="all")
                ]
            )
        ),
        yaxis2=attr(
            overlaying="y",
            side="right"
        ),        
        updatemenus=[attr(
            buttons=node_buttons
        )]
    ))
end
