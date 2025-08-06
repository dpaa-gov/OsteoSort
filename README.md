## OsteoSort 1.4.0

## Changes
This is a beta version of 1.4.0.

## Installation
```sh
git clone https://github.com/jjlynch2/OsteoSort
docker build -t osteosort .
docker run --restart=on-failure:10 -d -p 4001:3838 osteosort
```

## R Dependencies
* DT
* shiny
* htmltools
* zip
* JuliaCall
* ggplot2
* shinyalerts
* grid
* dplyr

## Julia Dependencies
* Statistics
* Optim
* Rmath
* GLM
* RCall
* Suppressor
* OSJ (local OsteoSort package)

## Citation
Lynch, J.J. 2025 OsteoSort. Computerized Osteometric Sorting. Version 1.4.0. Defense POW/MIA Accounting Agency, Offutt AFB, NE.

## TODO
1. Fix deprecated argument in GLM package

2. Change UI for reference
   OPTION 1
   Can we use the osteosort flag in the DB to pull in measurements + bones? that makes more sense. 
   That way I can avoid having those defined IN osteosort so the DB can update osteosort UI.
   I can grab full name for tooltips from that too.


3. Add calls for postgres db

4. Rebuild JSON CoRA API

5. Julia is still installing dependencies... I missed one in the sysimage. Find out what it is.

6. Type my arrays for caching see this 

7. Regression helper Compelex... is abstract. find new eltypes see above

8. Functions aren't pre-compiled. Could it be tails type is wrong? Double check what R pushes over. Push to Julia then check types.