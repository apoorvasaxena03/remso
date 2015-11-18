function [ duC,dx,dv,xi,lowActive,upActive,mu,violation,qpVAl,dxN,dvN,s,k] = qpStep(M,g,w,ldu,udu,Aact1,predictor,constraintBuilder,ax,Ax,ldx,udx,av,Av,ldv,udv,varargin )
% Solves the Convex - QP problem:
%
%      qpVAl = min 1/2 duC'*M*du + (g + (1-xi*) w ) * duC
%             s,duC  st.
%                    ldx - s <= (1-xi*)*ax + Ax * duC  <= udx + s
%                    ldv - s <= (1-xi*)*av + Av * duC  <= udv + s
%                    ldu <= duC <= udu
%                    s = sM
%
% where xiM = min xi + bigM s
%          s,duC,xi st.
%                   ldx - s <= (1-xi)*ax + Ax * duC <= udx + s
%                   ldv - s <= (1-xi)*av + Av * duC <= udv + s
%                   lbu <= duC <= udu
%                   0 <= xi <= 1
%                   0 <= s  <= 1/bigM
%
%  The problem is solved iteratively.  We start with a subset of the
%  constraints. Given the solution of the iteration i, the violated
%  constratins are identified and included to the prevoius problem and re-solved.
%
% SYNOPSIS:
%  [ duC,dx,dv,lowActive,upActive,mu,s,violationH,qpVAl] = prsqpStep(M,g,w,u,lbu,ubu,Ax,ldx,udx,Av,ldv,udv )
%  [ duC,dx,dv,lowActive,upActive,mu,s,violationH,qpVAl] = prsqpStep(M,g,w,u,lbu,ubu,Ax,ldx,udx,Av,ldv,udv , 'pn', pv, ...)
% PARAMETERS:
%
%  Vectors and matrices to form the problem above, some of the represented
%  with cellarrays, related to the strucutre of the problem
%
%   'pn'/pv - List of 'key'/value pairs defining optional parameters. The
%             supported options are:
%
%   qpDebug - if true print information
%
%   lowActive, upActive - represent a guess for the set of tight constraints.
%
%   feasTol - Tolerance to judge the constraint activity
%             Judge the optimality condition quality and debug
%             Judge the feasibility of the problem.
%
%   ci - control incidence function
%
%   maxQpIt - Maximum number of QP iterations
%
%   it - remso it number for debug
%
% RETURNS:
%          listed the non-obvious (see the problem definition above)
%
%   dx = Ax * duC
%   dv = Av * duC
%   lowActive,upActive - tight constraints at the optimal solution.
%   mu - dual variables for the inequality constraints of the QP problem
%   violationH = Vector of norm1 of the constraint violation per iteration.
%
% SEE ALSO:
%
%


opt = struct('qpDebug',true,'lowActive',[],'upActive',[],'feasTol',1e-6,'ci',[],'maxQpIt',20,'it',0,'bigM',1e9,'withAlgs',false,'condense',true,'nCons',100);
opt = merge_options(opt, varargin{:});

if isempty(opt.ci)
    opt.ci = @(kk)controlIncidence([],kk);
end

%assert(opt.feasTol*10>1/opt.bigM,'Make sure bigM is big enough compared to feasTol');
opt.bigM = max(opt.bigM,10/opt.feasTol);

withAlgs = opt.withAlgs;

xibar = 1;

if opt.qpDebug
    if opt.it <= 1
        fid = fopen('logQP.txt','w');
        fidCplex = fopen('logCplex.txt','w');
    else
        fid = fopen('logQP.txt','a');
        fidCplex = fopen('logCplex.txt','a');
        
    end
    fprintf(fid,'********************* Iteration %3.d ********************\n',opt.it);
    fprintf(fid,'it xi      slack   AddCons LP-TIME ST infViol NewCons QP-TIME ST\n');

    
    fprintf(fidCplex,'********************* Iteration %3.d ********************\n',opt.it);
    
    DisplayFunc = @(x) fprintf(fidCplex,[x,'\n']);
else
    DisplayFunc = [];
end



uDims = cellfun(@numel,ldu);
xDims = cellfun(@numel,udx);

if withAlgs
    vDims = cellfun(@numel,udv);
end

nuH = sum(uDims);


du = [];
dx = [];
dv = [];

violationH = [];


lowActiveP = opt.lowActive;
upActiveP = opt.upActive;

linesAdded.ub.x = upActiveP.x;
linesAdded.lb.x = lowActiveP.x;
if withAlgs
    linesAdded.ub.v = upActiveP.v;
    linesAdded.lb.v = lowActiveP.v;
end

newCons = cell(opt.maxQpIt+1,1);
nc = cell(opt.maxQpIt+1,1);

% mantain a record of the constraints added at each iteration
newCons{1} = linesAdded;

% count the number of new constraints
nc{1}.ub.x = sum(cellfun(@sum,linesAdded.ub.x));
nc{1}.lb.x = sum(cellfun(@sum,linesAdded.lb.x));
if withAlgs
    nc{1}.ub.v = sum(cellfun(@sum,linesAdded.ub.v));
    nc{1}.lb.v = sum(cellfun(@sum,linesAdded.lb.v));
end

violation = [];
solved = false;


nAddRows = 0;


P = Cplex('LP - QP');
P.DisplayFunc = DisplayFunc;
P.Param.qpmethod.Cur = 6;
P.Param.lpmethod.Cur = 6;
P.Param.emphasis.numerical.Cur = 1;


% Add control variables
P.addCols(zeros(nuH+2,1), [], [0;0;cell2mat(ldu)], [1;1/opt.bigM;cell2mat(udu)]);  % objective will be set up again later
P.Param.timelimit.Cur = 7200;

Q = blkdiag(1,1,M);
% CPLEX keeps complaining that the approximation is not symmetric
%if ~issymmetric(Q)
%	warning('Hessian approximation seems to be not symmetric')
%end
Q = (Q+Q')/2;

for k = 1:opt.maxQpIt
    
    
    if opt.condense
    
        % extract the current constraints lines to add in this iteration
        [ Alow.x,blow.x,xRlow ] = buildActiveConstraints(Ax,ldx,newCons{k}.lb.x,-1,'R',ax);
        [ Aup.x,bup.x,xRup ]   = buildActiveConstraints(Ax,udx,newCons{k}.ub.x,1,'R',ax);
        if withAlgs
            [ Alow.v,blow.v,vRlow ] = buildActiveConstraints(Av,ldv,newCons{k}.lb.v,-1,'R',av);
            [ Aup.v,bup.v,vRup ]   = buildActiveConstraints(Av,udv,newCons{k}.ub.v,1,'R',av);
            Aact = cell2mat([Alow.x;Aup.x;Alow.v;Aup.v]);
        else
            Aact = cell2mat([Alow.x;Aup.x]);
        end      
    else
        blow.x = cellfun(@(x,a)-x(a),ldx,newCons{k}.lb.x,'UniformOutput',false);
        xRlow =  cellfun(@(x,a)-x(a),ax ,newCons{k}.lb.x,'UniformOutput',false);
        bup.x =  cellfun(@(x,a) x(a),udx,newCons{k}.ub.x,'UniformOutput',false);
        xRup =   cellfun(@(x,a) x(a),ax ,newCons{k}.ub.x,'UniformOutput',false);

        if withAlgs
            blow.v = cellfun(@(x,a)-x(a),ldv,newCons{k}.lb.v,'UniformOutput',false);
            vRlow =  cellfun(@(x,a)-x(a),av ,newCons{k}.lb.v,'UniformOutput',false);
            bup.v =  cellfun(@(x,a) x(a),udv,newCons{k}.ub.v,'UniformOutput',false);
            vRup =   cellfun(@(x,a) x(a),av ,newCons{k}.ub.v,'UniformOutput',false);	
        end    
        
        if (k == 1 && ~isempty(Aact1))
            Aact = cell2mat(Aact1);
        else
            Aact = cell2mat(constraintBuilder(newCons{k}));    
        end
        
    end
    
    if withAlgs
        xRs = cell2mat([[xRlow;xRup;vRlow;vRup], [cellfun(@(xi)-ones(sum(xi),1),newCons{k}.lb.x,'UniformOutput',false);...
                                               cellfun(@(xi)-ones(sum(xi),1),newCons{k}.ub.x,'UniformOutput',false);...
                                               cellfun(@(xi)-ones(sum(xi),1),newCons{k}.lb.v,'UniformOutput',false);...
                                               cellfun(@(xi)-ones(sum(xi),1),newCons{k}.ub.v,'UniformOutput',false)]]);           

    else
        xRs = cell2mat([[xRlow;xRup], [cellfun(@(xi)-ones(sum(xi),1),newCons{k}.lb.x,'UniformOutput',false);...
                                        cellfun(@(xi)-ones(sum(xi),1),newCons{k}.ub.x,'UniformOutput',false)]]);                 
    end
                
    % Merge constraints in one matrix !
    
    Aq = [xRs,Aact];
    if withAlgs
        bq = cell2mat([blow.x;bup.x;blow.v;bup.v]);
    else
        bq = cell2mat([blow.x;bup.x]);
    end    
    
    if opt.qpDebug
        fprintf(fidCplex,'************* LP %d  ******************\n',k);
    end
    
    
    % now add the new rows
    P.addRows(-inf(size(bq)),Aq,bq);
    
	P.Model.lb(1) = 0;
    P.Model.ub(1) = 1;
	P.Model.lb(2) = 0;
    P.Model.ub(2) = 1/opt.bigM;
    
    % keep track of the number of constraints added so far
    nAddRows = nAddRows + numel(bq);
    
    
    % Set up the LP objective
    P.Model.Q = [];
    LPobj = [-1;opt.bigM;zeros(nuH,1)];
    P.Model.obj = LPobj;
    
    
    tic;
    P.solve();
    lpTime = toc;
    
    lpTime2 = 0;
    if (P.Solution.status ~= 1)
        method = P.Solution.method;
        status = P.Solution.status;
        if P.Solution.method == 2
            P.Param.lpmethod.Cur = 4;
        else
            P.Param.lpmethod.Cur = 2;
        end
        tic;
        P.solve();
        lpTime2 = toc;
        
        if (P.Solution.status ~= 1)
            if opt.qpDebug
                fprintf(fid,['Problems solving LP\n' ...
                    'Method ' num2str(method) ...
                    ' Status ' num2str(status) ...
                    ' Time %1.1e\n' ...
                    'Method ' num2str(P.Solution.method) ...
                    ' Status ' num2str(P.Solution.status)...
                    ' Time %1.1e\n'],lpTime,lpTime2) ;
            end
            warning(['Problems solving LP\n Method ' num2str(method) ' Status ' num2str(status) '\n Method ' num2str(P.Solution.method)  ' Status ' num2str(P.Solution.status)]);
        end
        
        P.Param.lpmethod.Cur = 6;
    end
    
    % Determine the value of 'xibar', for the current iteration ,see the problem difinition above
    xibar = min(max(P.Solution.x(1),0),1);
    sM = max(P.Solution.x(2),0);
    
    if opt.qpDebug
        fprintf(fid,'%2.d %1.1e %1.1e %1.1e %1.1e %2.d ',k,1-xibar,sM,nAddRows,lpTime+lpTime2,P.Solution.status) ;
        fprintf(fidCplex,'************* QP %d  *******************\n',k);
    end
    
    % set up the qp objective
    err = checkSolutionFeasibility(P);
    P.Model.Q = Q;
    B =cell2mat(g) + xibar * cell2mat(w);
    P.Model.obj = [0;opt.bigM;B'];
    P.Model.lb(1) = xibar;
    P.Model.ub(1) = xibar;
    %P.Model.lb(2) = sM;
    P.Model.ub(2) = sM + err;
    
    tic;
    P.solve();
    QpTime = toc;
    
    QpTime2 = 0;
    if (P.Solution.status ~= 1)
        method = P.Solution.method;
        status = P.Solution.status;
        if P.Solution.method == 2
            P.Param.qpmethod.Cur = 4;
        else
            P.Param.qpmethod.Cur = 2;
        end
        tic;
        P.solve();
        QpTime2 = toc;
        if (P.Solution.status ~= 1)
            if opt.qpDebug
                fprintf(fid,['Problems solving QP\n' ...
                    'Method ' num2str(method) ...
                    ' Status ' num2str(status) ...
                    ' Time %1.1e\n' ...
                    'Method ' num2str(P.Solution.method) ...
                    ' Status ' num2str(P.Solution.status)...
                    ' Time %1.1e\n'],QpTime,QpTime2) ;
            end
            warning(['\nProblems solving QP\n Method ' num2str(method) ' Status ' num2str(status) '\n Method ' num2str(P.Solution.method)  ' Status ' num2str(P.Solution.status)]);
        end
        
        P.Param.qpmethod.Cur = 6;
    end
    
    
    
    du = P.Solution.x(3:end);
    
    
    duC = mat2cell(du,uDims,1);
    
    if opt.condense

        dxN = cellmtimes(Ax,duC,'lowerTriangular',true,'ci',opt.ci);
        if withAlgs
            dvN = cellmtimes(Av,duC,'lowerTriangular',true,'ci',opt.ci);
        else
            dvN = [];
        end
    
    else
        
        [dxN,dvN] = predictor(duC);
    end
    
    du = duC;
    dx = cellfun(@(z,dz)xibar*z+dz,ax,dxN,'UniformOutput',false);
    if withAlgs
        dv = cellfun(@(z,dz)xibar*z+dz,av,dvN,'UniformOutput',false);
    end
    
    % Check which other constraints are infeasible
    [feasible.x,lowActive.x,upActive.x,violation.x ] = checkConstraintFeasibility(dx,ldx,udx,'primalFeasTol',0,'first',opt.nCons ) ;
    if withAlgs
        [feasible.v,lowActive.v,upActive.v,violation.v ] = checkConstraintFeasibility(dv,ldv,udv,'primalFeasTol',0,'first',opt.nCons  );
    end
    
    
    % debugging purpouse:  see if the violation is decreasing!
    ineqViolation = violation.x;
    if withAlgs
        ineqViolation = max(ineqViolation,violation.v);
    end
    
    violationH = [violationH,ineqViolation];
    
    
    
    % Determine the new set of contraints to be added
    [newCons{k+1}.lb.x,nc{k+1}.lb.x] =  newConstraints(linesAdded.lb.x, lowActive.x);
    [newCons{k+1}.ub.x,nc{k+1}.ub.x] =  newConstraints(linesAdded.ub.x, upActive.x);
    if withAlgs
        [newCons{k+1}.lb.v,nc{k+1}.lb.v] =  newConstraints(linesAdded.lb.v, lowActive.v);
        [newCons{k+1}.ub.v,nc{k+1}.ub.v] =  newConstraints(linesAdded.ub.v, upActive.v);
    end
    
    % determine how many new constraints are being added in total
    newC = 0;
    bN = fieldnames(nc{k+1});
    for bi = 1:numel(bN)
        vN = fieldnames(nc{k+1}.(bN{bi}));
        for vi = 1:numel(vN);
            newC  = newC + nc{k+1}.(bN{bi}).(vN{vi});
        end
    end
    
    
    if opt.qpDebug
        fprintf(fid,'%1.1e %1.1e %1.1e %2.d\n',ineqViolation,newC,QpTime+QpTime2,P.Solution.status) ;
    end
    
	if opt.qpDebug && nAddRows > 0

        xl = cell(k,1);
        xu = cell(k,1);
        vl = cell(k,1);
        vu = cell(k,1);
        for j = 1:k
            xl{j} = cellfun(@(z,i)-z(i),dxN,newCons{j}.lb.x,'UniformOutput',false);
            xu{j} = cellfun(@(z,i) z(i),dxN,newCons{j}.ub.x,'UniformOutput',false);
            vl{j} = cellfun(@(z,i)-z(i),dvN,newCons{j}.lb.v,'UniformOutput',false);
            vu{j} = cellfun(@(z,i) z(i),dvN,newCons{j}.ub.v,'UniformOutput',false);

        end
        
        dz =[xl{:};
             xu{:};
             vl{:};
             vu{:}];
         dz = reshape(dz,numel(dz),1);
         dz = cell2mat(dz);
        
          gradError = norm(P.Model.A(:,3:end)*P.Solution.x(3:end)-dz,inf);
          if gradError > opt.feasTol;
             fprintf(fid,'norm(gradError,inf) =  %e  > %e = qpFeasTol \n',gradError,opt.feasTol) ;
          end 
          
	end
    
    
    % if we cannot add more constraints, so the problem is solved!
    if newC == 0 || ineqViolation < opt.feasTol 
        if ineqViolation > opt.feasTol
            if opt.qpDebug
                fprintf(fid,'Irreductible constraint violation inf norm: %e \n',ineqViolation) ;
            end
        end
        solved = true;
        break;
    end
    
    
    linesAdded.lb.x = unionActiveSets(linesAdded.lb.x,lowActive.x);
    linesAdded.ub.x = unionActiveSets(linesAdded.ub.x,upActive.x);
    if withAlgs
        linesAdded.lb.v = unionActiveSets(linesAdded.lb.v,lowActive.v);
        linesAdded.ub.v = unionActiveSets(linesAdded.ub.v,upActive.v);
    end
    
end
if ~solved
    warning('Qps were not solved within the iteration limit')
end

xi = max(min(1-xibar,1),0);  %Cplex returning points with infinitesimal violation
s = sM;

if isfield(P.Solution,'dual')
    dual = P.Solution.dual;
else
    dual = [];
end


% extract the dual variables:
to = 0;  %% skip xibar and sM dual constraint!
for j = 1:k
    from = to + 1;
    to = from + nc{j}.lb.x-1;
    [r] = extractCompressIneq(-dual(from:to),newCons{j}.lb.x,xDims);
    if j==1
        mu.lb.x = r;
    else
        mu.lb.x = cellfun(@(x1,x2)x1+x2,mu.lb.x,r,'UniformOutput',false);
    end
    
    from = to + 1;
    to = from + nc{j}.ub.x-1;
    [r] = extractCompressIneq(-dual(from:to),newCons{j}.ub.x,xDims);
    if j==1
        mu.ub.x = r;
    else
        mu.ub.x = cellfun(@(x1,x2)x1+x2,mu.ub.x,r,'UniformOutput',false);
    end
    
    if withAlgs
        from = to + 1;
        to = from + nc{j}.lb.v-1;
        [r] = extractCompressIneq(-dual(from:to),newCons{j}.lb.v,vDims);
        if j==1
            mu.lb.v = r;
        else
            mu.lb.v = cellfun(@(x1,x2)x1+x2,mu.lb.v,r,'UniformOutput',false);
        end
        
        from = to + 1;
        to = from + nc{j}.ub.v-1;
        [r] = extractCompressIneq(-dual(from:to),newCons{j}.ub.v,vDims);
        if j==1
            mu.ub.v = r;
        else
            mu.ub.v = cellfun(@(x1,x2)x1+x2,mu.ub.v,r,'UniformOutput',false);
        end
    end
end
if to ~= size(P.Model.rhs,1)
    error('checkSizes!');
end

%%%  First order optimality
%norm(P.Model.Q * P.Solution.x + P.Model.obj -(P.Model.A)' * dual - P.Solution.reducedcost)


% extract dual variables with respect to the controls
mu.ub.u = mat2cell(max(-P.Solution.reducedcost(3:nuH+2),0),uDims,1);
mu.lb.u = mat2cell(max( P.Solution.reducedcost(3:nuH+2),0),uDims,1);


% Make sure that only the non-weakly active constraints are kept for the
% next iteration.
lowActive.x = cellfun(@(l)l>0,mu.lb.x,'UniformOutput',false);
upActive.x = cellfun(@(l)l>0,mu.ub.x,'UniformOutput',false);
lowActive.v = cellfun(@(l)l>0,mu.lb.v,'UniformOutput',false);
upActive.v = cellfun(@(l)l>0,mu.ub.v,'UniformOutput',false);


if opt.qpDebug
    if opt.condense
        if withAlgs
            optCheck = cell2mat(duC)'*M + B + ...
                cell2mat(cellmtimesT( cellfun(@(x1,x2)x1-x2,mu.ub.x,mu.lb.x,'UniformOutput',false),Ax ,'lowerTriangular',true,'ci',opt.ci)) + ...
                cell2mat(cellmtimesT( cellfun(@(x1,x2)x1-x2,mu.ub.v,mu.lb.v,'UniformOutput',false),Av,'lowerTriangular',true,'ci',opt.ci)) + ...
                cell2mat(             cellfun(@(x1,x2)x1-x2,mu.ub.u,mu.lb.u,'UniformOutput',false))';
        else
            optCheck = cell2mat(duC)'*M + B + ...
                cell2mat(cellmtimesT( cellfun(@(x1,x2)x1-x2,mu.ub.x,mu.lb.x,'UniformOutput',false),Ax ,'lowerTriangular',true,'ci',opt.ci)) + ...
                cell2mat(             cellfun(@(x1,x2)x1-x2,mu.ub.u,mu.lb.u,'UniformOutput',false))';
        end

        optNorm = norm(optCheck);
        fprintf(fid,'Optimality norm: %e \n',optNorm) ;
        if optNorm > opt.feasTol*10
            warning('QP optimality norm might be to high');
        end
    end
end


qpVAl = P.Solution.objval;

if opt.qpDebug
    
    
    fclose(fid);
end

end

function err = checkSolutionFeasibility(P)

dxP = P.Model.A*P.Solution.x;
err = max([P.Model.lhs - dxP;dxP - P.Model.rhs;0]);

end

