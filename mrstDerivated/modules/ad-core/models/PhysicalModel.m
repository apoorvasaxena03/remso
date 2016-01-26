classdef PhysicalModel
%Base class for physical models
%
% SYNOPSIS:
%   model = PhysicalModel(G)
%
% DESCRIPTION:
%   Base class for implementing physical models for use with automatic
%   differentiation. This class cannot be used directly.
%
%   A physical model instance contains the functions for getting residuals
%   and jacobians, making a single nonlinear step and verifying
%   convergence. It also contains the functions for updating the state
%   based on the increments found by the linear solver so that the values
%   are physically correct.
%
% REQUIRED PARAMETERS:
%
%   G     - Simulation grid.
%
% OPTIONAL PARAMETERS (supplied in 'key'/value pairs ('pn'/pv ...)):
%   See class properties.
%
% RETURNS:
%   Class instance.
%
% SEE ALSO:
%   ThreePhaseBlackOilModel, TwoPhaseOilWaterModel, ReservoirModel

%{
Copyright 2009-2015 SINTEF ICT, Applied Mathematics.

This file is part of The MATLAB Reservoir Simulation Toolbox (MRST).

MRST is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

MRST is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with MRST.  If not, see <http://www.gnu.org/licenses/>.
%}

%{
Changes by Codas

Inclusion of the functions: getEquationsDimensions
                            solveForwardGrad
                            solveAdjointStete0Sens
                            getDrivingForcesJacobian

%}

    properties
        % Operators used for construction of systems
        operators
        % Inf norm tolerance for nonlinear iterations
        nonlinearTolerance
    % Grid. Can be empty.
        G
        % Verbosity from model routines
        verbose
        % Model step function is guaranteed to converge in a single step.
        % Do not enable this unless you are very certain that it is the
        % case!
        stepFunctionIsLinear
    end
    
    methods
    function model = PhysicalModel(G, varargin)
            model.nonlinearTolerance = 1e-6;
            model.verbose = mrstVerbose();
            model = merge_options(model, varargin{:});            
            model.G = G;

            model.stepFunctionIsLinear = false;
        end
        
        function [problem, state] = getEquations(model, state0, state, dt, drivingForces, varargin) %#ok
        % Get the set of linearized equations governing the system.
        % This should be a instance of the LinearizedProblem class
        % containing the residual equations + jacobians etc for the model.
        % 
        % We also return the state, because the equation setup can in 
        % some special cases modify the state.
        error('Base class not meant for direct use')
    end

    % --------------------------------------------------------------------%
        function [eqDims] = getEquationsDimensions(model, state0, state, dt, drivingForces, varargin) %#ok
            % Get the equations governing the system
            error('Base class not meant for direct use')
        end
        
        function [state, report] = updateState(model, state, problem, dx, drivingForces) %#ok
        % Update state based on Newton increments
            for i = 1:numel(problem.primaryVariables);
                 p = problem.primaryVariables{i};
                 % Update the state
                 state = model.updateStateFromIncrement(state, dx, problem, p);
            end
            report = [];
        end
        
    % --------------------------------------------------------------------%
    function [state, report] = updateAfterConvergence(model, state0, state, dt, drivingForces) %#ok
            % Update state based on non-linear increment after timestep has
            % converged. Defaults to doing nothing since not all models
            % require this.
        report = [];
        end
        
    % --------------------------------------------------------------------%
        function [convergence, values] = checkConvergence(model, problem, n)
            % Check and report convergence based on residual tolerances
            if nargin == 2
                n = inf;
            end
            
            values = norm(problem, n);
            convergence = all(values < model.nonlinearTolerance);
            
            if model.verbose
                for i = 1:numel(values)
                    fprintf('%s (%s): %2.2e\t', problem.equationNames{i}, problem.types{i}, values(i));
                end
                fprintf('\n')
            end
        end
        
    % --------------------------------------------------------------------%
        function [state, report] = stepFunction(model, state, state0, dt, drivingForces, linsolve, nonlinsolve, iteration, varargin)
            % Make a single linearized timestep
            onlyCheckConvergence = iteration > nonlinsolve.maxIterations;
            
            [problem, state] = model.getEquations(state0, state, dt, drivingForces, ...
                                       'ResOnly', onlyCheckConvergence, ...
                                       'iteration', iteration, ...
                                       varargin{:});
            problem.iterationNo = iteration;
            
            [convergence, values] = model.checkConvergence(problem);
            % Minimum number of iterations can be prescribed, i.e. we
            % always want at least one set of updates regardless of
            % convergence criterion.
        doneMinIts = iteration > nonlinsolve.minIterations;
            
            % Defaults
            failureMsg = '';
            failure = false;
            [linearReport, updateReport] = deal(struct());
        if (~(convergence && doneMinIts) && ~onlyCheckConvergence)
                % Get increments for Newton solver
                [dx, ~, linearReport] = linsolve.solveLinearProblem(problem, model);
                
                % Let the non-linear solver decide what to do with the
                % increments to get the best convergence
                dx = nonlinsolve.stabilizeNewtonIncrements(problem, dx);
                
                % Finally update the state. The physical model knows which
                % properties are actually physically reasonable.
                [state, updateReport] = model.updateState(state, problem, dx, drivingForces);
                if any(cellfun(@(d) ~all(isfinite(d)), dx))
                    failure = true;
                    failureMsg = 'Linear solver produced non-finite values.';
                end
            end
        isConverged = convergence || (model.stepFunctionIsLinear && doneMinIts);
            report = model.makeStepReport(...
                            'LinearSolver', linearReport, ...
                            'UpdateState',  updateReport, ...
                            'Failure',      failure, ...
                            'FailureMsg',   failureMsg, ...
                        'Converged',    isConverged, ...
                            'Residuals',    values);
        end
        
    % --------------------------------------------------------------------%
        function report = makeStepReport(model, varargin) %#ok
        % Get the standardized step report that all models produce.
            report = struct('LinearSolver', [], ...
                            'UpdateState',  [], ...
                            'Failure',      false, ...
                            'FailureMsg',   '', ...
                            'Converged',    false, ...
                        'FinalUpdate',  [],...
                            'Residuals',    []);
                        report = merge_options(report, varargin{:});
        end
        

        
        function [result,report] = solveForwardGrad(model, solver, getState,...
                 schedule,itNo,xRightSeeds,uRightSeeds)
                        
            dt_steps = schedule.step.val;
            
            current = getState(itNo);
            before    = getState(itNo - 1);
            dt = dt_steps(itNo);
            
            lookupCtrl = @(step) schedule.control(schedule.step.control(step));            
            
            [~, forces] = model.getDrivingForces(lookupCtrl(itNo));
            problem = model.getEquations(before, current, dt, forces, 'iteration', inf);
            problem = assembleSystem(problem);
            
            problem_p = model.getEquations(before, current , dt,forces,...
                'iteration', inf,...
                'reverseMode', true);
            problem_p = assembleSystem(problem_p);
            eqs_p = -problem_p.A;
            
            if size(xRightSeeds,1)~=0
                eqs_p = eqs_p(:,1:size(xRightSeeds,1)) * xRightSeeds;
            else
                eqs_p = eqs_p*0;
            end
            
            
            %%%%%%%%%%%%%
            %% TODO: Assumption (partial model) / (partial driving foces) = [0;...0;-I]
            dPdF = model.getDrivingForcesJacobian(before, current , dt,forces);
            
            rhs = (eqs_p+dPdF*uRightSeeds);                       
            
            
            problem.b = rhs;       
            
            
           [dx, result, rep] = solveLinearProblem(solver, problem, model);
           
            report = struct();
            report.Types = problem.types;
            report.LinearSolverReport = rep;
              
        end
        
        function [gradient, result, report] = solveAdjoint(model, solver, getState,...
                                    getObjective, schedule, gradient, itNo)
        % Solve the adjoint equations for a given step.
            dt_steps = schedule.step.val;
            
            current = getState(itNo);
            before    = getState(itNo - 1);
            dt = dt_steps(itNo);
            
            lookupCtrl = @(step) schedule.control(schedule.step.control(step));
            [~, forces] = model.getDrivingForces(lookupCtrl(itNo));
            problem = model.getEquations(before, current, dt, forces, 'iteration', inf);
            
            if itNo < numel(dt_steps)
                after    = getState(itNo + 1);
                dt_next = dt_steps(itNo + 1);
                
                [~, forces_p] = model.getDrivingForces(lookupCtrl(itNo + 1));
                problem_p = model.getEquations(current, after, dt_next, forces_p,...
                                    'iteration', inf, 'reverseMode', true);
            else
                problem_p = [];
            end
            [gradient, result, rep] = solver.solveAdjointProblem(problem_p,...
                                        problem, gradient, getObjective(itNo), model);
            report = struct();
            report.Types = problem.types;
            report.LinearSolverReport = rep;
        end
        
        
        
        function result = solveAdjointStete0Sens(model, getState,...
                                     schedule, gradient)
            
            itNo = 1;
                                
            dt_steps = schedule.step.val;
            
            current = getState(itNo);
            before    = getState(itNo - 1);
            dt = dt_steps(itNo);
            
            lookupCtrl = @(step) schedule.control(schedule.step.control(step));
            [~, forces_p] = model.getDrivingForces(lookupCtrl(itNo));
            
            problem_p = model.getEquations(before, current, dt, forces_p, 'iteration', inf,'reverseMode', true);
            
            problem_p = problem_p.assembleSystem();
            
            % the minus sign is due to the minus introduced in assembleSystem
            result = gradient'*problem_p.A;
            %{
            varnum = getEquationVarNum(problem_p);
            gradient = mat2cell(result,size(result,1),varnum');
            %}
        end        
        
        function [vararg, driving] = getDrivingForces(model, control) %#ok
            % Setup and pass on driving forces. Dummy version for base
        % class. Vararg should be suitable for passing as 
        % someFunction(a, b, vararg{:}) while driving should be a
        % struct containing the same information.
            vararg = {};
            driving = struct();
        end
        
        function [Jacobian] = getDrivingForcesJacobian(model,state0, state, dt, drivingForces)
            %% TODO: Assumption (partial model) / (partial driving foces) = [0;...0;-I]
            %  This is true for OW and OWG models in MRST, but it may not
            %  be in general
            error('Implement in a sub-class')
            Jacobian = [];

            
        end        
        
        function [fn, index] = getVariableField(model, name)
            % Get the index/name mapping for the model (such as where
            % pressure or water saturation is located in state). This
            % always result in an error, as this model knows of no variables.
        %
        % Given a name, this function produces the fieldname and the
        % index in the struct that can be used to get the same info.
            [fn, index] = deal([]);
            
            if isempty(index)
                error('PhysicalModel:UnknownVariable', ...
                    ['State variable ''', name, ''' is not known to this model']);
            end
        end
        
    % --------------------------------------------------------------------%
        function p = getProp(model, state, name)
        % Get a property based on the name. Uses getVariableField to
        % determine how to obtain the data for the name. Ex:
        %
        %  p = model.getProp(state, 'pressure');
        %
            [fn, index] = model.getVariableField(name);
            p = state.(fn)(:, index);
        end
        
    % --------------------------------------------------------------------%
        function varargout = getProps(model, state, varargin)
        % Get multiple properties based on their name(s). Multiple
        % names can be sent in as variable arguments, i.e.
        %
        % [p, s] = model.getProps(state, 'pressure', 's');
            varargout = cellfun(@(x) model.getProp(state, x), ...
                                varargin, 'UniformOutput', false);
        end
        
    % --------------------------------------------------------------------%
        function state = incrementProp(model, state, name, increment)
        % Increment property based on the name for the field. The
        % returned state contains incremented values.
        % 
        % Example:
        % state = struct('pressure', 0);
        % state = model.incrementProp(state, 'pressure', 1);
        %
        % state.pressure is now 1, if pressure was known to the model.
        % Otherwise we will get an error.
            [fn, index] = model.getVariableField(name);
            p = state.(fn)(:, index)  + increment;
            state.(fn)(:, index) = p;
        end
        
    % --------------------------------------------------------------------%
        function state = setProp(model, state, name, value)
        % Set property to given value based on name. 
        %
        % state = struct('pressure', 0);
        % state = model.setProp(model, state, 'pressure', 5);
        %
        % state.pressure is now 5, unless pressure is not a valid
        % field.
            [fn, index] = model.getVariableField(name);
            state.(fn)(:, index) = value;
        end
        
    % --------------------------------------------------------------------%
        function dv = getIncrement(model, dx, problem, name)
            % Find increment in linearized problem with given name, or
        % output zero if not found. A linearized problem can give
        % updates to multiple variables and this makes it easier to get
        % those values without having to know the order they were input
        % into the constructor.
            isVar = problem.indexOfPrimaryVariable(name);
            if any(isVar)
                dv = dx{isVar};
            else
                dv = 0;
            end
        end
        
    % --------------------------------------------------------------------%
        function [state, val, val0] = updateStateFromIncrement(model, state, dx, problem, name, relchangemax, abschangemax)
        % Update a state, with optionally maximum changes (relative and
        % absolute.
        %
        % Example:
        % state = struct('pressure', 10);
        %
        % state = model.updateStateFromIncrement(state, 100, problem, 'pressure')
        %
        % This will result in pressure being set to 100.
        %
        %  Consider now
        %
        % state = model.updateStateFromIncrement(state, 100, problem, 'pressure', .1)
        % 
        % The pressure will now be set to 10, as setting it to 100
        % directly will violate the maximum relative change.
        %
        % Relative limits such as these are important when dealing with
        % properties that are tabulated and non-smooth in a Newton-type
        % loop, as the initial updates may be far outside the
        % reasonable region of linearization for a complex problem.
        %
        % It can delay convergence for smooth problems with analytic
        % properties, so use with care.
            if iscell(dx)
            % We have cell array of increments, use the problem to
            % determine where we can actually find it.
                dv = model.getIncrement(dx, problem, name);
            else
                % Numerical value, increment directly and do not safety
                % check that this is a part of the model
                dv = dx;
            end
            
            val0 = model.getProp(state, name);
            
            [changeRel, changeAbs] = deal(1);
            if nargin > 5
                [~, changeRel] = model.limitUpdateRelative(dv, val0, relchangemax);
            end
            if nargin > 6
                [~, changeAbs] = model.limitUpdateAbsolute(dv, abschangemax);
            end            
            % Limit update by lowest of the relative and absolute limits 
            change = min(changeAbs, changeRel);
            
            val   = val0 + dv.*repmat(change, 1, size(dv, 2));
            state = model.setProp(state, name, val);
        end
        
    % --------------------------------------------------------------------%
        function state = capProperty(model, state, name, minvalue, maxvalue)
            % Cap values to min/max values
            v = model.getProp(state, name);
            v = max(minvalue, v);
            if nargin > 4
                v = min(v, maxvalue);
            end
            state = model.setProp(state, name, v);
        end
    end

    methods (Static)
    % --------------------------------------------------------------------%
        function [dv, change] = limitUpdateRelative(dv, val, maxRelCh)
            % Limit a update by relative limit
            biggestChange = max(abs(dv./val), [], 2);
            change = min(maxRelCh./biggestChange, 1);
            dv = dv.*repmat(change, 1, size(dv, 2));
        end
        
    % --------------------------------------------------------------------%
        function [dv, change] = limitUpdateAbsolute(dv, maxAbsCh)
            % Limit a update by absolute limit
            biggestChange = max(abs(dv), [], 2);
            change = min(maxAbsCh./biggestChange, 1);
            dv = dv.*repmat(change, 1, size(dv, 2));
        end
        
    % --------------------------------------------------------------------%
        function [vars, isRemoved] = stripVars(vars, names)
            isRemoved = cellfun(@(x) any(strcmpi(names, x)), vars);
            vars(isRemoved) = [];
        end
    end

end

