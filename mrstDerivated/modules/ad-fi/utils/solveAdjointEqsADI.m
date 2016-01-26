function [x, ii] = solveAdjointEqsADI(eqs, eqs_p, adjVec, objk, system)
% Codas -> Modified but compatible with the MRST version!
%
% modification to treat the vector-Jacobian case.
% optional cpr adjoint.
% flexibility to choose direct solvers
%

numVars = cellfun(@numval, eqs)';
cumVars = cumsum(numVars);
ii = [[1;cumVars(1:end-1)+1], cumVars];

if ~isnumeric(objk)
	if iscell(objk)
    	objk = objk{:};
	end
	objk = cat(objk);

	% Above CAT means '.jac' is a single element cell array.  Extract contents.
	rhs  = -objk.jac{1}';
else
	rhs  = -objk';
end

if ~isempty(adjVec)
    % If adjVec is not empty, we are not at the last timestep (first in the
    % adjoint recurrence formulation). This means that we subtract
    % the previous jacobian times the previous lagrange multiplier.
    % Previous here means at time t + 1.
    eqs_p = cat(eqs_p{:});
    
    % CAT means '.jac' is a single element cell array.
    rhs = rhs - eqs_p.jac{1}'*adjVec;
end
tic
if system.nonlinear.cprAdjoint
    [x, its, fl] = cprAdjoint(eqs, rhs, system, 'cprType', system.nonlinear.cprType, 'relTol', ...
        system.nonlinear.cprRelTol,...
       'cprEllipticSolver', system.nonlinear.cprEllipticSolver,...
       'directSolver' ,system.nonlinear.directSolver,...
       'iterative'  , system.nonlinear.itSolverAdjADI);
else
    eqs = cat(eqs{:});
    
    % CAT means '.jac' is a single element cell array.
    x = system.nonlinear.directSolver(eqs.jac{1}',rhs);
end
tt = toc;
dispif(false, 'Lin. eq: %6.5f seconds, ', tt);
