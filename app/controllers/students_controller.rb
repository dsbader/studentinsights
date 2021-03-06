class StudentsController < ApplicationController
  include SerializeDataHelper

  rescue_from Exceptions::EducatorNotAuthorized, with: :not_authorized

  before_action :authorize!, except: [:names]

  def authorize!
    student = Student.find(params[:id])
    educator = current_educator
    raise Exceptions::EducatorNotAuthorized unless educator.is_authorized_for_student(student)
  end

  def show
    redirect_to profile_student_path
  end

  def profile
    student = Student.find(params[:id])
    chart_data = StudentProfileChart.new(student).chart_data
    @serialized_data = {
      current_educator: current_educator,
      student: serialize_student_for_profile(student),
      notes: student.student_notes.map { |note| serialize_student_note(note) },
      feed: student_feed(student),
      chart_data: chart_data,
      intervention_types_index: intervention_types_index,
      service_types_index: service_types_index,
      event_note_types_index: event_note_types_index,
      educators_index: educators_index,
      attendance_data: {
        discipline_incidents: student.most_recent_school_year.discipline_incidents,
        tardies: student.most_recent_school_year.tardies,
        absences: student.most_recent_school_year.absences
      }
    }
  end

  def deprecated_v1_profile
    @student = Student.find(params[:id]).decorate
    @chart_start = params[:chart_start] || "mcas-growth"
    @chart_data = StudentProfileChart.new(@student).chart_data

    @student_risk_level = @student.student_risk_level.decorate

    @student_school_years = @student.student_school_years.includes(
      :discipline_incidents,
      :student_assessments,
      :interventions
    )

    interventions = @student.interventions.order(start_date: :desc)
    @serialized_interventions = interventions.map { |intervention| serialize_intervention(intervention) }

    student_notes = @student.student_notes
    @serialized_student_notes = student_notes.map { |note| serialize_student_note(note) }

    @roster_url = homeroom_path(@student.homeroom)
    @csv_url = deprecated_v1_profile_student_path(@student) + ".csv"

    respond_to do |format|
      format.html
      format.csv {
        render csv: StudentProfileCsvExporter.new(@student).profile_csv_export,
        filename: 'export'
      }
    end
  end

  def sped_referral
    @student = Student.find(params[:id])
    respond_to do |format|
      format.pdf do
        render pdf: "sped_referral"
      end
    end
  end

  # post
  def event_note
    clean_params = params.require(:event_note).permit(*[
      :student_id,
      :event_note_type_id,
      :text
    ])
    event_note = EventNote.new(clean_params.merge({
      educator_id: current_educator.id,
      recorded_at: Time.now
    }))
    if event_note.save
      render json: event_note.as_json
    else
      render json: { errors: event_note.errors.full_messages }, status: 422
    end
  end

  # post
  def service
    clean_params = params.require(:service).permit(*[
      :student_id,
      :service_type_id,
      :date_started,
      :provided_by_educator_id
    ])
    service = Service.new(clean_params.merge({
      recorded_by_educator_id: current_educator.id,
      recorded_at: Time.now
    }))
    if service.save
      render json: service.as_json
    else
      render json: { errors: service.errors.full_messages }, status: 422
    end
  end

  def names
    q = params[:q]
    authorized_students = Student.with_school.select do |student|
      current_educator.is_authorized_for_student(student)
    end
    sorted_students = search_and_score(q, authorized_students)
    @sorted_results = sorted_students.map {|student| student.decorate.presentation_for_autocomplete }

    respond_to do |format|
      format.json { render json: @sorted_results }
    end
  end

  private
  def not_authorized
    redirect_to not_authorized_path
  end

  def serialize_student_for_profile(student)
    student.as_json.merge({
      interventions: student.interventions.as_json,
      student_risk_level: student.student_risk_level.as_json,
      absences_count: student.most_recent_school_year.absences.count,
      tardies_count: student.most_recent_school_year.tardies.count,
      school_name: student.try(:school).try(:name),
      homeroom_name: student.try(:homeroom).try(:name),
      discipline_incidents_count: student.most_recent_school_year.discipline_incidents.count
    }).stringify_keys
  end

  def search_and_score(query, students)
    search_tokens = query.split(' ')
    students_with_scores = students.flat_map do |student|
      score = calculate_student_score(student, search_tokens)
      if score > 0 then [{ student: student, score: score }] else [] end
    end

    students_with_scores.sort_by {|ss| -1 * ss[:score] }.map {|ss| ss[:student] }
  end

  # range: [0.0, 1.0]
  def calculate_student_score(student, search_tokens)
    student_tokens = [student.first_name, student.last_name].compact
    
    search_token_scores = []
    search_tokens.each do |search_token|
      student_tokens.each do |student_token|
        if search_token.upcase == student_token[0..search_token.length - 1].upcase
          search_token_scores << 1
          break
        end
      end
    end
    
    (search_token_scores.sum.to_f / search_tokens.length)
  end

  def student_feed(student)
    {
      event_notes: student.event_notes,
      services: student.services,
      deprecated: {
        notes: student.student_notes.map { |note| serialize_student_note(note) },
        interventions: student.interventions.map { |intervention| serialize_intervention(intervention) }
      }
    }
  end
end
