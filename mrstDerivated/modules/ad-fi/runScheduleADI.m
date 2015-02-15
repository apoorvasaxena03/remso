function varargout = ...
   runScheduleADI(initState, G, rock, system, schedule, varargin)
% Given a schedule and a system, solve for all time steps
%
% SYNOPSIS:
%  [wellSols, states, its] = runScheduleADI(initState, G, rock, system, schedule)
%  [wellSols, states, its] = runScheduleADI(initState, G, rock, system, ...
%                                           schedule, 'pn', pv, ...)
% PARAMETERS:
%   initState - The initial state at t = 0;
%
%   G         - A valid grid. See grid_structure.
%
%   rock      - A valid rock structure. Should contain an Nx1 array
%               'poro' containing cell wise porosity values. A permeability
%               field is not *needed* for all the ad-fi solvers as they can
%               work directly with transmissibilities, but it is
%               highly recommended to supply them in either a Nx1 or Nx3
%               array. N is here equal to G.cells.num.
%
%  system     - System configuration as defined by initADISystem.
%
%  schedule   - Schedule (usually found in the deck.SCHEDULE field from
%               the return value of readEclipseDeck from the deckformat
%               module). This fully defines the well configurations for all
%               timesteps.
%
%   'pn'/pv - List of 'key'/value pairs defining optional parameters.  The
%             supported options are:
%           
%   Verbose - If verbose output should be outputted. Defaults to
%             mrstVerbose.
%
%   writeOutput - Save output to the cache folder. This can be practical
%                 when states becomes too big to solve in memory or when
%                 running adjoint simulations.
%
%   outputName  - The string which prefixes output files if
%                 writeOutput is enabled. Defaults to 'state'.
%
%   outputWellSolName - The string which prefixes well output files if writeOutput is enabled. Defaults to 'wellSol'.
%
%   outputSchedule - If true, write updated schedule for given time step. Useful
%   when time splitting is used and we want to restart a computation at a given time-step.
%
%
%   wellDepthReorder - If true, well's connections are reordered by depth (default value : false). 
%
%
%
% RETURNS:
%   wellSols - Well solution struct for each timestep. Cellarray of size
%              Ntx1.
%
%   states (OPTIONAL) - State solution struct for each timestep. Cellarray
%                       of size Ntx1. Note that as this can be come
%                       prohibitively big for long simulations this should
%                       be only outputted if neded.
%
%   its (OPTIONAL) - Nonlinear iteration count for each timestep.
%
%
% SEE ALSO:
%   solvefiADI

%{
Copyright 2009-2014 SINTEF ICT, Applied Mathematics.

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
Codas change: 
*Inclusion of initialGuess
*Output of convergence and jacobians
*Print debug removal
*exclude the initial conditions from the output
*optinal step size control, by default false 
*Adapatations deal with step refinement,
%}


default_outputDir = fullfile(fileparts(mfilename('fullpath')), 'cache');

opt = struct('Verbose'       , mrstVerbose      , ...
             'writeOutput'   , false            , ...
             'outputName'    , 'state'          , ...
             'outputWellSolName', 'wellSol'        , ...
             'outputSchedule'   , false            , ...
             'wellDepthReorder' , false            , ...
             'scaling'       , []               , ...
             'startAt'       , 1                , ...
             'outputDir'     , default_outputDir, ...
             'plotCallback'  , [],  ...
             'outputNameFunc', [],...
             'force_step'    , true, ...
             'stop_if_not_converged', true, ...
			 'control_step', false, ...
             'minStepSize'   , day/4,...
             'initialGuess',[] );
         
opt = merge_options(opt, varargin{:});

vb = opt.Verbose;
outputStates =      nargout > 1;
outputSchedule    = nargout > 2; % Refined schedule is given as output. Useful when time refinement
                                 % is used (force_step = false)
outputIter        = nargout > 3;
outputConvergence = nargout > 4;
outputJacs = nargout > 5;


%--------------------------------------------------------------------------

dt = schedule.step.val;
tm = cumsum(dt);
dispif(vb, '*****************************************************************\n')
dispif(vb, '********** Starting simulation: %5.0f steps, %5.0f days *********\n', numel(dt), tm(end)/day)
dispif(vb, '*****************************************************************\n')

%--------------------------------------------------------------------------

if opt.writeOutput
    %delete existing output
    % delete(fullfile(directory, [opt.outputName, '*.mat']));
    % output file-names

    if ~isdir(opt.outputDir),
       [success, msg, id] = mkdir(opt.outputDir);
       if ~ success,
          error(id, 'Failed to create output diretory ''%s'': %s', ...
                opt.outputDir, msg);
       end
    end

    if isempty(opt.outputNameFunc)
       outNm  = @(tstep)fullfile(opt.outputDir, sprintf('%s%05.0f', opt.outputName, tstep));
    else
       outNm  = @(tstep)fullfile(opt.outputDir, opt.outputNameFunc(tstep)); 
    end
    wellOutNm = @(tstep)fullfile(opt.outputDir, sprintf('%s%05.0f', opt.outputWellSolName, ...
                                                      tstep));
    if opt.outputSchedule
       scheduleOutNm = @(tstep)fullfile(opt.outputDir, sprintf('schedule%05.0f', ...
                                                         tstep));
    end
end


%--------------------------------------------------------------------------
% output initState
state = initState;
if opt.writeOutput, save(outNm(0), 'state');end;

%--------------------------------------------------------------------------
% collect all wellsols in cell wellsols
wellSols = cell(numel(dt), 1);

if outputStates
    states = cell(numel(dt), 1);
    initState.wellSol = initWellSolLocal([], state);
end
if outputJacs
    Jacs = cell(numel(dt), 1);
end

iter = [];

%--------------------------------------------------------------------------
% default is to report all steps
if ~isfield(schedule.step, 'repStep')
    schedule.step.repStep = true(numel(dt), 1);
end

prevControl = -1;
timero = tic;
repStep = 0;
convergence = [];
useMrstSchedule = isfield(schedule.control(1), 'W');
if useMrstSchedule
    nw = arrayfun(@(x)numel(x.W), schedule.control);
    uniformSchedule = all(nw == nw(1));
    if uniformSchedule
        W_temp = schedule.control(1).W;
        for k = 1 : numel(W_temp) 
           W_temp(k).status = true; 
        end
        wellSol_init = initWellSolLocal(W_temp, state);  % initial guess (updated after each time-step)
        for k = 1 : numel(W_temp)
           W_temp(k).status = false; % Default well is shut down 
        end
        wellSol_zero = initWellSolLocal(W_temp, state);  % default 0-well-sol
    end
end

tstep = 1;
t = 0;

% ref_dt gives an estimate of a time step which yields a number of Newton iterations equal to targetIts.
ref_dt = schedule.step.val(1);
   
while tstep <= numel(schedule.step.val)
   dispif(vb, 'Time step %5.0f of %d\n', tstep, numel(schedule.step.val));
   control = schedule.step.control(tstep);
   if control ~= prevControl
      if control == 0, % when is control == 0 ?
         W = processWellsLocal(G, rock, [], 'createDefaultWell', true);
      else
         if ~useMrstSchedule
            W = processWellsLocal(G, rock, schedule.control(control), ...
                                 'Verbose', opt.Verbose, ...
                                  'DepthReorder', opt.wellDepthReorder);
         else
            W = schedule.control(control).W;
         end
      end
   end
   if isfield(W,'status')  %% remove closed wells if any
      openWells = vertcat(W.status);
   else
      openWells = true(numel(W),1);
   end
   dispif(vb, 'Time step length: %g day.\n', convertTo(schedule.step.val(tstep), day))
   state0 = state;
   if useMrstSchedule && uniformSchedule
      state0.wellSol = initWellSolLocal(W(openWells), state, wellSol_init(openWells));
   else
      state0.wellSol = initWellSolLocal(W(openWells), state);
   end

   dt = schedule.step.val(tstep);

    if (isempty(opt.initialGuess))
      [state, its, conv,eqs] = solvefiADI(state0, schedule.step.val(tstep), W(openWells), G, system);
    else
      [state, its, conv,eqs] = solvefiADI(state0, schedule.step.val(tstep), W(openWells), G, system,'initialGuess',opt.initialGuess{tstep});
    end

   proceed_to_next_step = true;
   
   if ~(conv.converged) 
      if opt.force_step & opt.stop_if_not_converged
         error(['You may try time step refinement: set ''force_step'' option equal to false in ', ...
                'runScheduleADI.']);
      elseif ~opt.force_step
            % split time step
            if tstep > 1
            	dispif(opt.Verbose,'Cutting time step on day %d, new step size = %d!\n',schedule.time/day ,schedule.step.val(tstep)/day);
            else
                dispif(opt.Verbose,'Cutting time step on day %d, new step size = %d!\n',schedule.time/day + sum(schedule.step.val(1:tstep-1))/day ,schedule.step.val(tstep)/day);
            end
         schedule = splitTimeStep(schedule, tstep);
         if ~isempty(opt.initialGuess)
            opt.initialGuess = [opt.initialGuess(1:tstep) opt.initialGuess(tstep:end)];
            opt.initialGuess{tstep} = mrstStateConvexComb(0.5,state0,opt.initialGuess{tstep});  %% somthing better for wellSol?
         end
         dispif(opt.Verbose,'New step size: %.5g day.\n', schedule.step.val(tstep)/day);
         if opt.control_step
            ref_dt = ref_dt/2;
         end
         if ref_dt < opt.minStepSize 
            if opt.stop_if_not_converged
               error('Minimum step size refinement has been reached.')
            else
               proceed_to_next_step = true;
            end
         else
            state = state0;
            proceed_to_next_step = false;
         end
      end
   end

   if proceed_to_next_step
   
    % check if any controls have been switched, and if so update W
      optloc = {'allowWellSignChange', system.well.allowWellSignChange, 'allowControlSwitching', ...
                system.well.allowControlSwitching, 'Verbose', opt.Verbose};
      W(openWells) = updateSwitchedControls(state.wellSol, W(openWells), ...
                                            optloc{:});
    
      
      iter = [iter; its];
      t  = t + schedule.step.val(tstep);
      
    if useMrstSchedule && uniformSchedule
        wellSol_init(openWells) = state.wellSol;
         wellSol = wellSol_zero;
         wellSol(openWells) = state.wellSol;
         state.wellSol = wellSol;
      else
         wellSol = state.wellSol;
    end
      wellSols{tstep} = wellSol;
    wellSols{tstep} = addWellInfo(wellSols{tstep}, W);
    if outputStates
        states{tstep} = state;
    end
    if outputJacs
        Jacs{tstep} = eqs;
    end
    if ~isempty(opt.plotCallback)
        opt.plotCallback(G, state)
    end
    
    prevControl = control;
    if opt.writeOutput && schedule.step.repStep(tstep)
        repStep = repStep + 1;
        save(outNm(repStep), 'state'); 
         save(wellOutNm(repStep), 'wellSol');
         if opt.outputSchedule
            save(scheduleOutNm(repStep), 'schedule');
         end
    end
    convergence = [convergence; conv]; %#ok
    dispif(opt.Verbose, 'Step %4g of %4g (Used %3g iterations)\n', ...
             tstep, numel(schedule.step.val), its);

      dt_history=[];
 
      if opt.control_step
          [dt_new, dt_history] = simpleStepSelector(dt_history, ref_dt, its,...
                                                    'targetIts', 10, ...
                                                    'stepModifier', 1.5);
 
          if tstep < numel(schedule.step.val) && dt_new < schedule.step.val(tstep + 1)
             schedule = refineSchedule(t, dt_new, schedule);
             if ref_dt < dt_new
                fprintf('*** Increased time step\n');
             elseif ref_dt > dt_new
                fprintf('*** Decreased time step\n');
             end
             ref_dt = dt_new;
          end
       end
      
      tstep = tstep + 1;
   end
   
end

timend = toc(timero);
dispif(vb, ['************Simulation done: %7.2f seconds ', ...
            '********************\n'], timend)
varargout{1} = wellSols;

if opt.writeOutput
   save(fullfile(opt.outputDir, 'wellSols'), 'wellSols');
end

if outputStates
    varargout{2} = states;
end

if outputSchedule
   varargout{3} = schedule;
end

if outputIter
   varargout{4} = iter;
end

if outputConvergence
   varargout{5} = convergence;
end

if nargout > 5
    varargout{6} = Jacs;
end

end

%--------------------------------------------------------------------------

function wellSol = addWellInfo(wellSol, W)
   %nm = fieldnames(W);
   nm = {'name', 'sign'};
   for k = 1:numel(nm)
      for wnum = 1:numel(W)
         wellSol(wnum).(nm{k}) = W(wnum).(nm{k});
      end
   end
end
