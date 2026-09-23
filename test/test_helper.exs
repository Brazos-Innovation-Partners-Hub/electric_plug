db? = System.get_env("ELECTRIC_PLUG_DB") not in [nil, "0"]
ExUnit.start(exclude: if(db?, do: [], else: [:db]))
