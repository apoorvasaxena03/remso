REMSO - REservoir Multiple Shooting Optimizer.
      - REduced Multiple Shooting Optimizer.


REMSO is an optimization algorithm based on Multiple Shooting. It is developed thinking about reservoir control optimization applications. REMSO exploits:

*Parallelism.
*Reduction techniques.
*Automatic differentiation.

REMSO is tightly interfaced to MRST (currently MRST-2015a) and exploits the structure of the module ad-fi (Automatic Differentiation - Fully Implicit). Functionalities within MRST are modified or extended to enable REMSO to calculate simulations in parallel and gradient computations.

Compared to conventional integration of reservoir simulators and optimizers, REMSO allows for much more flexibility to deal with output constraints.

REMSO solves the optimal control NLP problem by a sequence of QP's. CPLEX (currently V12.6) is used for this purpose. Observe that CPLEX can be downloaded for educational applications under their Academic Initiative Program.


To run REMSO, it is required:
- Matlab (tested on 2015a).
- CPLEX interfaced to matlab (tested with V12.6).
- MRST (tested with 2015a).

REMSO was interfaced to other versions of Matlab and MRST but it is recommended to run the tested versions.

Running the example files (specially simpleRes) should be straightforward. Please follow the example scripts to check that your installation is functional. There in no plan for a formal documentation for REMSO, however the most important parts of the code are commented. Debugging the examples may help to understand all the functionalities.

REMSO is under continuous development and test. The MASTER branch contains a version that was considerably tested and which performance results were submitted for publication. During the revision process that branch will maintain the code related to the latest submission. Only bug-fixes that will not affect the reproducibility of the publication will be included. Meanwhile, other branches, for ex. 2014b, will merge MRST updates and new features.

REMSO can be interfaced to other simulators besides MRST. A simple example interfacing REMSO to ACADO is given.

Besides the optimization code for Multiple Shooting, this framework can instantiate a Single Shooting formulation and solve it with IPOPT or SNOPT. 

REMSO is being developed by Andres Codas (andres.codas at itk.ntnu.no) during his Ph.D studies which are supported by the IO-Center at NTNU in Norway (http://www.iocenter.no/). All users are encouraged to contact him for questions and possible collaboration.

Copyright 2013-2016, Andres Codas.

REMSO is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

REMSO is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with REMSO.  If not, see <http://www.gnu.org/licenses/>.
